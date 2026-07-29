#!/bin/bash
# DIBar release pipeline. See RELEASING.md for the full story.
#
# Usage: scripts/release.sh <marketing-version> [--build N]
#   e.g. scripts/release.sh 1.4        (build number = current + 1)
#        scripts/release.sh 1.4 --build 9
#
# Publishes the GitHub release BEFORE pushing appcast.xml, so the Sparkle feed
# never points at an asset that is not yet downloadable.

set -euo pipefail

REPO="drmikexo2/DIBar-macOS"
FEED_RAW_URL="https://raw.githubusercontent.com/${REPO}/main/appcast.xml"
ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-$HOME/.dibar/sparkle_private_key}"
NOTARY_PROFILE="DIBar"
TEAM_ID="FA2AMFV98N"

cd "$(dirname "$0")/.."
PBXPROJ="DIBar.xcodeproj/project.pbxproj"

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

RELEASE_WORK_DIR=""
VERSION_BUMPED=false
RELEASE_COMMIT_CREATED=false
APPCAST_MODIFIED=false
APPCAST_COMMITTED=false
PHASE="argument parsing"

cleanup() {
    local status=$?
    trap - EXIT

    if [[ "$status" -ne 0 ]]; then
        printf '\nRelease failed during: %s\n' "$PHASE" >&2
        if [[ "$VERSION_BUMPED" == true && "$RELEASE_COMMIT_CREATED" == false ]]; then
            git restore -- "$PBXPROJ" >/dev/null 2>&1 || true
            printf 'Restored the project version; fix the cause and rerun the script.\n' >&2
        elif [[ "$RELEASE_COMMIT_CREATED" == true ]]; then
            printf 'The release commit may already be local or published. Do not rerun.\n' >&2
            printf 'Continue from the matching recovery step in RELEASING.md.\n' >&2
        fi
        if [[ "$APPCAST_MODIFIED" == true && "$APPCAST_COMMITTED" == false ]]; then
            git restore -- appcast.xml >/dev/null 2>&1 || true
            printf 'Restored the last published appcast.\n' >&2
        fi
    fi

    if [[ -n "$RELEASE_WORK_DIR" && -d "$RELEASE_WORK_DIR" ]]; then
        case "$RELEASE_WORK_DIR" in
            */dibar-release.*) rm -rf -- "$RELEASE_WORK_DIR" ;;
            *) printf 'WARNING: refusing to remove unexpected work directory: %s\n' "$RELEASE_WORK_DIR" >&2 ;;
        esac
    fi

    exit "$status"
}
trap cleanup EXIT

# --- Arguments ---------------------------------------------------------------

VERSION="${1:-}"
[[ -n "$VERSION" ]] || fail "usage: scripts/release.sh <marketing-version> [--build N]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "version '$VERSION' is not X.Y or X.Y.Z"
shift

BUILD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD="${2:?--build needs a number}"; shift 2 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

# --- Preflight ---------------------------------------------------------------

PHASE="preflight"
say "Preflight"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
[[ "$(git branch --show-current)" == "main" ]] || fail "not on main"

for command_name in git gh xcodebuild xcrun security ditto codesign spctl shasum curl open; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

git pull --ff-only >/dev/null

CUR_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | grep -o '[0-9]\+')
[[ -n "$BUILD" ]] || BUILD=$((CUR_BUILD + 1))
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "build number '$BUILD' is not an integer"

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
[[ -f "$ED_KEY_FILE" ]] || fail "Sparkle EdDSA key not found at $ED_KEY_FILE"
[[ -f "DIBar/Services/Secrets.swift" ]] || fail "DIBar/Services/Secrets.swift missing (cp the .example)"
grep -Fqx "## ${VERSION}" CHANGELOG.md || fail "CHANGELOG.md has no '## ${VERSION}' section"
! gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1 || fail "release v${VERSION} already exists"
CODE_SIGN_IDENTITIES=$(security find-identity -v -p codesigning)
[[ "$CODE_SIGN_IDENTITIES" == *"Developer ID Application"*"$TEAM_ID"* ]] \
    || fail "Developer ID Application signing identity for team $TEAM_ID not found"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || fail "notarization keychain profile '$NOTARY_PROFILE' is unavailable"

SPARKLE_BIN=""
for candidate in "$HOME/.dibar/sparkle-tools" \
                 "$HOME"/Library/Developer/Xcode/DerivedData/DIBar-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    [[ -x "$candidate/generate_appcast" ]] && SPARKLE_BIN="$candidate" && break
done
[[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/sign_update" ]] \
    || fail "Sparkle tools not found (expected in ~/.dibar/sparkle-tools)"

# Build numbers must strictly increase: Sparkle compares CFBundleVersion.
APPCAST_BUILD=$(grep -o '<sparkle:version>[0-9]*' appcast.xml \
    | grep -o '[0-9]*' | sort -n | tail -1 || true)
APPCAST_BUILD="${APPCAST_BUILD:-0}"
[[ "$BUILD" -gt "$CUR_BUILD" ]] || fail "build $BUILD must be > current pbxproj build $CUR_BUILD"
[[ "$BUILD" -gt "$APPCAST_BUILD" ]] || fail "build $BUILD must be > appcast build $APPCAST_BUILD"
echo "version $VERSION, build $BUILD (pbxproj was $CUR_BUILD, appcast was $APPCAST_BUILD)"

RELEASE_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dibar-release.XXXXXX")
ARCHIVE="${RELEASE_WORK_DIR}/DIBar.xcarchive"
EXPORT="${RELEASE_WORK_DIR}/export"
APP="${EXPORT}/DIBar.app"
NOTARIZE_ZIP="${RELEASE_WORK_DIR}/DIBar-notarize.zip"
VERIFY_DIR="${RELEASE_WORK_DIR}/verify"
NOTES_FILE="${RELEASE_WORK_DIR}/release-notes.md"
ZIP="dist/DIBar-v${VERSION}-macOS.zip"
CHECKSUM="${ZIP}.sha256"

# --- Bump versions -----------------------------------------------------------

PHASE="version bump"
say "Bumping pbxproj to MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD"
VERSION_BUMPED=true
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "$PBXPROJ"

# --- Test --------------------------------------------------------------------

PHASE="tests"
say "Running tests"
xcodebuild -project DIBar.xcodeproj -scheme DIBar -destination 'platform=macOS' test -quiet

# --- Build, notarize, package ------------------------------------------------

PHASE="archive"
say "Archiving"
xcodebuild -project DIBar.xcodeproj -scheme DIBar -configuration Release \
    -archivePath "$ARCHIVE" archive -quiet

PHASE="Developer ID export"
say "Exporting (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist ExportOptions.plist -quiet

PHASE="notarization"
say "Notarizing (profile: $NOTARY_PROFILE)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

PHASE="packaging"
say "Packaging $ZIP"
rm -f -- "$ZIP" "$CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "DIBar-v${VERSION}-macOS.zip" > "DIBar-v${VERSION}-macOS.zip.sha256")

# --- Release commit + GitHub release -----------------------------------------

PHASE="release commit"
say "Committing release and publishing GitHub release"
awk -v heading="## ${VERSION}" '
    $0 == heading { flag=1; next }
    flag && /^## / { exit }
    flag
' CHANGELOG.md > "$NOTES_FILE"
[[ -s "$NOTES_FILE" ]] || fail "extracted empty release notes for ${VERSION}"

git add "$PBXPROJ" CHANGELOG.md
git commit -m "Release DIBar ${VERSION}"
RELEASE_COMMIT_CREATED=true

PHASE="release commit push"
git push

PHASE="GitHub release"
gh release create "v${VERSION}" --repo "$REPO" --title "DIBar ${VERSION}" \
    --notes-file "$NOTES_FILE" "$ZIP" "$CHECKSUM"

# --- Verify the published asset byte-for-byte --------------------------------

PHASE="published asset verification"
say "Verifying published asset matches local zip"
mkdir "$VERIFY_DIR"
gh release download "v${VERSION}" --repo "$REPO" --pattern "DIBar-v${VERSION}-macOS.zip" --dir "$VERIFY_DIR"
LOCAL_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
REMOTE_SHA=$(shasum -a 256 "$VERIFY_DIR/DIBar-v${VERSION}-macOS.zip" | awk '{print $1}')
[[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] || fail "sha256 mismatch: local $LOCAL_SHA vs published $REMOTE_SHA"
echo "sha256 match: $LOCAL_SHA"

# --- Appcast (signed against the asset GitHub actually serves) ---------------

PHASE="appcast generation"
say "Generating signed appcast entry"
APPCAST_MODIFIED=true
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$ED_KEY_FILE" \
    --download-url-prefix "https://github.com/${REPO}/releases/download/v${VERSION}/" \
    -o appcast.xml "$VERIFY_DIR"

SIG=$("$SPARKLE_BIN/sign_update" --ed-key-file "$ED_KEY_FILE" "$VERIFY_DIR/DIBar-v${VERSION}-macOS.zip" \
    | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
if ! grep -q "sparkle:edSignature" appcast.xml; then
    # generate_appcast omits the signature for archives whose app predates
    # Sparkle; inject the one sign_update produced.
    sed -i '' "s|<enclosure url=\"https://github.com/${REPO}/releases/download/v${VERSION}/DIBar-v${VERSION}-macOS.zip\"|& sparkle:edSignature=\"${SIG}\"|" appcast.xml
fi
grep -q "sparkle:edSignature" appcast.xml || fail "appcast has no edSignature"

say "Verifying appcast signature"
APPCAST_SIG=$(grep -o 'sparkle:edSignature="[^"]*"' appcast.xml | head -1 | cut -d'"' -f2)
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$ED_KEY_FILE" \
    "$VERIFY_DIR/DIBar-v${VERSION}-macOS.zip" "$APPCAST_SIG"
echo "signature verifies"

# --- Publish the feed (only now that the asset is live) ----------------------

PHASE="appcast commit"
say "Pushing appcast"
git add appcast.xml
git commit -m "Update appcast for ${VERSION}"
APPCAST_COMMITTED=true

PHASE="appcast push"
git push

PHASE="feed CDN verification"
say "Waiting for raw.githubusercontent.com to serve the new feed"
for i in $(seq 1 12); do
    FEED_CONTENT=$(curl -fsSL "$FEED_RAW_URL" || true)
    if [[ "$FEED_CONTENT" == *"<sparkle:version>${BUILD}</sparkle:version>"* ]]; then
        echo "feed is live"
        break
    fi
    [[ "$i" -lt 12 ]] || echo "WARNING: feed not visible yet (CDN cache, up to ~5 min); check manually: $FEED_RAW_URL"
    sleep 30
done

PHASE="complete"
say "Done: DIBar ${VERSION} (build ${BUILD}) is released"
echo "The signed release archive is ready at: $ZIP"
open -R "$ZIP" || true
