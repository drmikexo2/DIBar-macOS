#!/bin/bash
# End-to-end check that an interrupted update recovers on the next launch.
#
# Usage: scripts/smoke-update.sh [--baseline <ref>]
#
# Sparkle keeps a downloaded-but-uninstalled update only in memory and
# otherwise resumes only by probing for a live installer process, so killing
# the app between extraction and install strands the update until the next
# scheduled check 24 hours later. This script reproduces exactly that: it
# serves a fake 2.0 update from localhost, kills the app the moment the update
# is extracted, relaunches, and asserts the app ends up on 2.0.
#
# --baseline <ref> first runs the same scenario against a pre-fix commit and
# requires it to FAIL to recover. Without that control a passing run proves
# nothing, so use it whenever the recovery logic changes.
#
# Everything is local: a throwaway bundle identifier with its own container and
# preferences, a feed on 127.0.0.1, no GitHub release, no change to the
# published appcast. The real DIBar install is never touched.

set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$PWD"

SMOKE_ID="com.di-fm-menubar.smoke"
OLD_VERSION="1.4.1"
OLD_BUILD=9
NEW_VERSION="2.0"
NEW_BUILD=100
ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-$HOME/.dibar/sparkle_private_key}"

# Progress goes to stderr: run_scenario is read with $(...) and its stdout must
# contain only the version the app ended up on.
say()  { printf '\n==> %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

WORK_DIR=""
SERVER_PID=""
BASELINE_WORKTREE=""

cleanup() {
    local status=$?
    trap - EXIT

    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    kill_smoke_processes

    defaults delete "$SMOKE_ID" >/dev/null 2>&1 || true
    rm -rf -- "$HOME/Library/Containers/$SMOKE_ID/Data/Library/Preferences/$SMOKE_ID.plist" 2>/dev/null || true
    rm -rf -- "$HOME/Library/Caches/$SMOKE_ID" "$HOME/Library/Caches/$SMOKE_ID.sparkle" 2>/dev/null || true

    if [[ -n "$BASELINE_WORKTREE" && -d "$BASELINE_WORKTREE" ]]; then
        git -C "$PROJECT_DIR" worktree remove --force "$BASELINE_WORKTREE" 2>/dev/null || true
    fi

    if [[ -n "${KEEP_WORK_DIR:-}" ]]; then
        printf 'Keeping work dir for inspection: %s\n' "$WORK_DIR" >&2
    elif [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        case "$WORK_DIR" in
            */dibar-smoke.*) rm -rf -- "$WORK_DIR" ;;
            *) printf 'WARNING: refusing to remove unexpected work dir: %s\n' "$WORK_DIR" >&2 ;;
        esac
    fi

    exit "$status"
}
trap cleanup EXIT

# Kill by bundle identifier and by work-dir path prefix, not just this run's
# work dir: a leftover app from an earlier run holds the <id>-spki installer
# service, and a second app with the same bundle id then sees an installer
# already running and defers its own check indefinitely.
# Match any run's install path, not just this one's: a leftover app from an
# earlier run holds the <id>-spki installer service, and a second app with the
# same bundle id then sees an installer already running and defers its own
# check indefinitely. The app, Installer.xpc, Autoupdate, and Updater all carry
# this path in their argv. Deliberately narrow: a looser "dibar-smoke." pattern
# also matches the python feed server, whose --directory lives under the same
# work dir, and killing that silently breaks every download.
kill_smoke_processes() {
    pkill -9 -f "dibar-smoke\.[^/]*/install/DIBar\.app" 2>/dev/null || true
    return 0
}

# --- Arguments ---------------------------------------------------------------

BASELINE_REF=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline) BASELINE_REF="${2:?--baseline needs a git ref}"; shift 2 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

# --- Preflight ---------------------------------------------------------------

say "Preflight"
for command_name in xcodebuild python3 ditto plutil defaults open pkill git; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

[[ -f "$ED_KEY_FILE" ]] || fail "Sparkle EdDSA key not found at $ED_KEY_FILE"
[[ -f "DIBar/Services/Secrets.swift" ]] || fail "DIBar/Services/Secrets.swift missing (cp the .example)"

SPARKLE_BIN=""
for candidate in "$HOME/.dibar/sparkle-tools" \
                 "$HOME"/Library/Developer/Xcode/DerivedData/DIBar-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    [[ -x "$candidate/generate_appcast" ]] && SPARKLE_BIN="$candidate" && break
done
[[ -n "$SPARKLE_BIN" ]] || fail "Sparkle tools not found (expected in ~/.dibar/sparkle-tools)"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dibar-smoke.XXXXXX")
INSTALL_APP="$WORK_DIR/install/DIBar.app"
FEED_DIR="$WORK_DIR/feed"
mkdir -p "$WORK_DIR/install" "$FEED_DIR"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
FEED_URL="http://127.0.0.1:${PORT}/appcast.xml"
info "work dir: $WORK_DIR"
info "feed: $FEED_URL"

# The only difference from the shipping plist. Passing it via INFOPLIST_FILE
# means the source tree is untouched and the build signs normally.
SMOKE_PLIST="$WORK_DIR/Info-smoke.plist"
cp DIBar/Info.plist "$SMOKE_PLIST"
plutil -replace SUFeedURL -string "$FEED_URL" "$SMOKE_PLIST"

# --- Build helpers -----------------------------------------------------------

# build_app <source-dir> <derived-data-name> <version> <build> <destination>
build_app() {
    local source_dir="$1" dd_name="$2" version="$3" build="$4" destination="$5"
    local derived="$WORK_DIR/$dd_name"

    ( cd "$source_dir" && xcodebuild \
        -project DIBar.xcodeproj -scheme DIBar -configuration Release \
        -derivedDataPath "$derived" \
        INFOPLIST_FILE="$SMOKE_PLIST" \
        PRODUCT_BUNDLE_IDENTIFIER="$SMOKE_ID" \
        MARKETING_VERSION="$version" \
        CURRENT_PROJECT_VERSION="$build" \
        build -quiet >&2 ) || fail "build failed for $source_dir ($version)"

    rm -rf -- "$destination"
    ditto "$derived/Build/Products/Release/DIBar.app" "$destination"
}

app_version() {
    defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?"
}

# wait_for <timeout-seconds> <description> <command...>
wait_for() {
    local timeout="$1" description="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

# Sparkle's staging root is <bundle-id> on some systems and <bundle-id>.sparkle
# on others, so match both rather than pinning one layout.
extracted_update_exists() {
    compgen -G "$HOME/Library/Caches/$SMOKE_ID"*"/org.sparkle-project.Sparkle/Installation/*/*/DIBar.app" >/dev/null
}

# Recovery asks before installing, so the test has to answer. Without this the
# app sits on the modal forever and the run times out.
click_install_and_relaunch() {
    osascript -e 'tell application "System Events" to tell process "DIBar" to click button "Install and Relaunch" of window 1' \
        >/dev/null 2>&1
}

prompt_was_logged() {
    /usr/bin/log show --predicate \
        'subsystem == "com.dibar" AND category == "Updates"' \
        --last 3m --info --style compact 2>/dev/null | grep -q "was downloaded but not installed"
}

recheck_was_logged() {
    /usr/bin/log show --predicate \
        'subsystem == "com.dibar" AND category == "Updates"' \
        --last 3m --info --style compact 2>/dev/null | grep -q "rechecking"
}

diagnose_stalled_check() {
    printf '\n--- diagnostics ---\n' >&2
    printf 'running processes:\n' >&2
    pgrep -lf "DIBar" >&2 || printf '  (none)\n' >&2
    printf 'app path launched: %s\n' "$INSTALL_APP" >&2
    printf 'feed reachable: ' >&2
    curl -fsS "$FEED_URL" -o /dev/null && printf 'yes\n' >&2 || printf 'NO\n' >&2
    printf 'smoke prefs:\n' >&2
    defaults read "$SMOKE_ID" 2>&1 | grep -E 'SU[A-Z]' >&2 || printf '  (no SU keys)\n' >&2
    printf 'sparkle caches:\n' >&2
    ls -d "$HOME/Library/Caches/$SMOKE_ID"* 2>/dev/null >&2 || printf '  (none)\n' >&2
    printf 'DIBar update log (absent on the pre-fix baseline):\n' >&2
    /usr/bin/log show --predicate 'subsystem == "com.dibar" AND category == "Updates"' \
        --last 5m --info --style compact 2>/dev/null | tail -10 >&2
    printf 'sparkle log:\n' >&2
    /usr/bin/log show --predicate 'subsystem == "org.sparkle-project.Sparkle"' \
        --last 5m --info --debug --style compact 2>/dev/null | tail -20 >&2
    printf 'crash/launch log:\n' >&2
    /usr/bin/log show --predicate "process == \"DIBar\"" --last 5m --style compact 2>/dev/null | tail -15 >&2
    printf -- '--- end diagnostics ---\n\n' >&2
}

installed_is_new_version() {
    [[ "$(app_version "$INSTALL_APP")" == "$NEW_VERSION" ]]
}

# containermanagerd owns the container directory itself, so clear its contents
# rather than trying (and failing) to remove the container.
reset_smoke_state() {
    kill_smoke_processes
    sleep 2
    defaults delete "$SMOKE_ID" >/dev/null 2>&1 || true
    rm -rf -- "$HOME/Library/Containers/$SMOKE_ID/Data/Library/Preferences/$SMOKE_ID.plist" 2>/dev/null || true
    rm -rf -- "$HOME/Library/Containers/$SMOKE_ID/Data/Library/Caches/$SMOKE_ID" 2>/dev/null || true
    rm -rf -- "$HOME/Library/Caches/$SMOKE_ID" "$HOME/Library/Caches/$SMOKE_ID.sparkle" 2>/dev/null || true
}

# --- Build the fake 2.0 update and sign a local feed --------------------------

say "Building the 2.0 update"
build_app "$PROJECT_DIR" "dd-update" "$NEW_VERSION" "$NEW_BUILD" "$WORK_DIR/update/DIBar.app"
ditto -c -k --sequesterRsrc --keepParent "$WORK_DIR/update/DIBar.app" "$FEED_DIR/DIBar-v${NEW_VERSION}-macOS.zip"

say "Signing the local appcast"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$ED_KEY_FILE" \
    --download-url-prefix "http://127.0.0.1:${PORT}/" \
    -o "$FEED_DIR/appcast.xml" "$FEED_DIR"
grep -q "sparkle:edSignature" "$FEED_DIR/appcast.xml" || fail "generated appcast has no edSignature"
info "advertised build: $(grep -o '<sparkle:version>[0-9]*' "$FEED_DIR/appcast.xml" | head -1 | grep -o '[0-9]*')"

say "Serving the feed on 127.0.0.1:${PORT}"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED_DIR" >/dev/null 2>&1 &
SERVER_PID=$!
wait_for 10 "feed" curl -fs "$FEED_URL" -o /dev/null || fail "local feed did not come up"

# --- The scenario ------------------------------------------------------------

# run_scenario <source-dir> <derived-data-name> <label>
# Echoes the version the app ends up on.
run_scenario() {
    local source_dir="$1" dd_name="$2" label="$3"

    say "Scenario: $label"
    reset_smoke_state
    build_app "$source_dir" "$dd_name" "$OLD_VERSION" "$OLD_BUILD" "$INSTALL_APP"
    info "installed $(app_version "$INSTALL_APP")"

    # Fresh preferences mean no SULastCheckTime, so Sparkle checks right after
    # launch. SUEnableAutomaticChecks in the plist suppresses the first-run
    # permission prompt.
    open "$INSTALL_APP"
    if ! wait_for 180 "extraction" extracted_update_exists; then
        diagnose_stalled_check
        fail "$label: update never downloaded and extracted"
    fi
    info "update extracted; killing the app mid-flight"

    # No graceful quit: this is what a reboot looks like to Sparkle.
    kill_smoke_processes
    sleep 2
    [[ "$(app_version "$INSTALL_APP")" == "$OLD_VERSION" ]] \
        || fail "$label: app updated before the interruption; the test proved nothing"
    info "still $OLD_VERSION after the interruption, as expected"

    open "$INSTALL_APP"
    if wait_for 90 "recovery prompt" prompt_was_logged; then
        info "recovery prompt logged"
        # Answer the modal. The pre-fix baseline never shows one, so this is a
        # no-op there and the scenario still ends on the old version.
        wait_for 30 "install button" click_install_and_relaunch && info "clicked Install and Relaunch"
    else
        info "no recovery prompt"
    fi

    wait_for 120 "install" installed_is_new_version || true
    # Fall back to a graceful quit, which completes an install that was staged
    # for quit rather than performed immediately.
    if ! installed_is_new_version; then
        osascript -e "tell application id \"$SMOKE_ID\" to quit" >/dev/null 2>&1 || true
        wait_for 60 "install on quit" installed_is_new_version || true
    fi
    sleep 3
    kill_smoke_processes

    app_version "$INSTALL_APP"
}

EXIT_STATUS=0

if [[ -n "$BASELINE_REF" ]]; then
    say "Preparing baseline worktree at $BASELINE_REF"
    BASELINE_WORKTREE="$WORK_DIR/baseline"
    git worktree add --detach "$BASELINE_WORKTREE" "$BASELINE_REF" >/dev/null \
        || fail "could not create baseline worktree for $BASELINE_REF"
    # Secrets.swift is gitignored, so a fresh worktree cannot build without it.
    cp DIBar/Services/Secrets.swift "$BASELINE_WORKTREE/DIBar/Services/Secrets.swift"

    BASELINE_RESULT=$(run_scenario "$BASELINE_WORKTREE" "dd-baseline" "baseline ($BASELINE_REF), expected to STAY on $OLD_VERSION")
    if [[ "$BASELINE_RESULT" == "$OLD_VERSION" ]]; then
        info "baseline ended on $BASELINE_RESULT - bug reproduced, the test can detect it"
    else
        printf 'ERROR: baseline ended on %s; it recovered, so this test does not detect the bug\n' \
            "$BASELINE_RESULT" >&2
        EXIT_STATUS=1
    fi
fi

FIXED_RESULT=$(run_scenario "$PROJECT_DIR" "dd-fixed" "current tree, expected to RECOVER to $NEW_VERSION")

say "Result"
[[ -n "$BASELINE_REF" ]] && info "baseline ($BASELINE_REF): ended on ${BASELINE_RESULT}"
info "current tree: ended on ${FIXED_RESULT}"

if [[ "$FIXED_RESULT" != "$NEW_VERSION" ]]; then
    printf 'FAIL: interrupted update did not recover (ended on %s, wanted %s)\n' \
        "$FIXED_RESULT" "$NEW_VERSION" >&2
    exit 1
fi

[[ "$EXIT_STATUS" -eq 0 ]] || exit "$EXIT_STATUS"
say "PASS: an interrupted update recovers on the next launch"
