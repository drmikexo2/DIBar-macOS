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

cd "$(dirname "$0")/.."
PBXPROJ="DIBar.xcodeproj/project.pbxproj"

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

CUR_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | grep -o '[0-9]\+')
[[ -n "$BUILD" ]] || BUILD=$((CUR_BUILD + 1))
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "build number '$BUILD' is not an integer"

# --- Preflight ---------------------------------------------------------------

say "Preflight"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
[[ "$(git branch --show-current)" == "main" ]] || fail "not on main"
git pull --ff-only >/dev/null
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
[[ -f "$ED_KEY_FILE" ]] || fail "Sparkle EdDSA key not found at $ED_KEY_FILE"
[[ -f "DIBar/Services/Secrets.swift" ]] || fail "DIBar/Services/Secrets.swift missing (cp the .example)"
grep -q "^## ${VERSION}\$" CHANGELOG.md || fail "CHANGELOG.md has no '## ${VERSION}' section"
! gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1 || fail "release v${VERSION} already exists"

SPARKLE_BIN=""
for candidate in "$HOME/.dibar/sparkle-tools" \
                 "$HOME"/Library/Developer/Xcode/DerivedData/DIBar-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    [[ -x "$candidate/generate_appcast" ]] && SPARKLE_BIN="$candidate" && break
done
[[ -n "$SPARKLE_BIN" ]] || fail "Sparkle tools not found (expected in ~/.dibar/sparkle-tools)"

# Build numbers must strictly increase: Sparkle compares CFBundleVersion.
APPCAST_BUILD=$(grep -o '<sparkle:version>[0-9]*' appcast.xml | grep -o '[0-9]*' | sort -n | tail -1)
[[ "$BUILD" -gt "$CUR_BUILD" ]] || fail "build $BUILD must be > current pbxproj build $CUR_BUILD"
[[ "$BUILD" -gt "${APPCAST_BUILD:-0}" ]] || fail "build $BUILD must be > appcast build $APPCAST_BUILD"
echo "version $VERSION, build $BUILD (pbxproj was $CUR_BUILD, appcast was ${APPCAST_BUILD:-none})"

# --- Bump versions -----------------------------------------------------------

say "Bumping pbxproj to MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "$PBXPROJ"

# --- Test --------------------------------------------------------------------

say "Running tests"
xcodebuild -project DIBar.xcodeproj -scheme DIBar -destination 'platform=macOS' test -quiet

# --- Build, notarize, package ------------------------------------------------

ARCHIVE="dist/DIBar-${VERSION}.xcarchive"
EXPORT="dist/export-${VERSION}"
APP="${EXPORT}/DIBar.app"
ZIP="dist/DIBar-v${VERSION}-macOS.zip"

say "Archiving"
xcodebuild -project DIBar.xcodeproj -scheme DIBar -configuration Release \
    -archivePath "$ARCHIVE" archive -quiet

say "Exporting (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist ExportOptions.plist -quiet

say "Notarizing (profile: $NOTARY_PROFILE)"
ditto -c -k --keepParent "$APP" "dist/DIBar-v${VERSION}-notarize.zip"
xcrun notarytool submit "dist/DIBar-v${VERSION}-notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

say "Packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "DIBar-v${VERSION}-macOS.zip" > "DIBar-v${VERSION}-macOS.zip.sha256")

# --- Release commit + GitHub release -----------------------------------------

say "Committing release and publishing GitHub release"
NOTES_FILE=$(mktemp)
awk "/^## ${VERSION}\$/{flag=1; next} /^## /{flag=0} flag" CHANGELOG.md > "$NOTES_FILE"
[[ -s "$NOTES_FILE" ]] || fail "extracted empty release notes for ${VERSION}"

git add "$PBXPROJ" CHANGELOG.md
git commit -m "Release DIBar ${VERSION}"
git push
gh release create "v${VERSION}" --repo "$REPO" --title "DIBar ${VERSION}" \
    --notes-file "$NOTES_FILE" "$ZIP" "${ZIP}.sha256"

# --- Verify the published asset byte-for-byte --------------------------------

say "Verifying published asset matches local zip"
VERIFY_DIR=$(mktemp -d)
gh release download "v${VERSION}" --repo "$REPO" --pattern "DIBar-v${VERSION}-macOS.zip" --dir "$VERIFY_DIR"
LOCAL_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
REMOTE_SHA=$(shasum -a 256 "$VERIFY_DIR/DIBar-v${VERSION}-macOS.zip" | awk '{print $1}')
[[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] || fail "sha256 mismatch: local $LOCAL_SHA vs published $REMOTE_SHA"
echo "sha256 match: $LOCAL_SHA"

# --- Appcast (signed against the asset GitHub actually serves) ---------------

say "Generating signed appcast entry"
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

say "Pushing appcast"
git add appcast.xml
git commit -m "Update appcast for ${VERSION}"
git push

say "Waiting for raw.githubusercontent.com to serve the new feed"
for i in $(seq 1 12); do
    if curl -fsSL "$FEED_RAW_URL" | grep -q "<sparkle:version>${BUILD}</sparkle:version>"; then
        echo "feed is live"
        break
    fi
    [[ "$i" -lt 12 ]] || echo "WARNING: feed not visible yet (CDN cache, up to ~5 min); check manually: $FEED_RAW_URL"
    sleep 30
done

say "Done: DIBar ${VERSION} (build ${BUILD}) is released"
echo "Install the shipped build locally with:"
echo "  cp -R \"$APP\" /Applications/"
