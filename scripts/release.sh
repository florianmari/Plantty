#!/usr/bin/env bash
# Publishes a signed, notarized Plantty release and announces it to Sparkle.
# usage: scripts/release.sh <version> <notes.md>     e.g. scripts/release.sh 0.1.3 notes.md
#
# Needs, once per Mac:
#   - a "Developer ID Application" certificate in the login Keychain (Xcode → Settings → Accounts → Manage Certificates)
#   - notarization credentials: xcrun notarytool store-credentials plantty-notary --apple-id <email> --team-id <team>
#   - the Sparkle EdDSA private key in the login Keychain (see AGENTS.md)
#
# Order matters: the GitHub release (with its files) goes up before appcast.xml is pushed,
# so the updater never offers a download that doesn't exist yet.
set -euo pipefail

VERSION="${1:?version, e.g. 0.1.3}"
NOTES="${2:?release notes markdown file}"
REPO="florianmari/Plantty"
NOTARY_PROFILE="${NOTARY_PROFILE:-plantty-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 0. Preflight: fail before touching anything.
[[ -f "$NOTES" ]] || { echo "notes file not found: $NOTES"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean; commit first"; exit 1; }
git fetch -q origin && [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not in sync with origin/main"; exit 1; }
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && { echo "v$VERSION already exists"; exit 1; }
DEVID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[[ -n "$DEVID" ]] || { echo "no 'Developer ID Application' certificate in the Keychain (Xcode → Settings → Accounts → Manage Certificates → +)"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "no notarization credentials; run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id <team>"; exit 1; }
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
echo "Signing as: $DEVID"

# 1. Bump version; the build number must always grow, Sparkle compares it.
BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

# 2. Build and test.
xcodegen generate -q
xcodebuild -project Plantty.xcodeproj -scheme Plantty -derivedDataPath build test -quiet
xcodebuild -project Plantty.xcodeproj -scheme Plantty -configuration Release -derivedDataPath build build -quiet
APP=build/Build/Products/Release/Plantty.app
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]

# 3. Sign with Developer ID, inside-out, hardened runtime + secure timestamp (both required by notarization).
sign() { codesign --force --timestamp --options runtime --sign "$DEVID" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements Plantty/Plantty.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# 4. Notarize the app and staple the ticket to it, so it opens offline without warnings.
notarize() {
  local out; out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; echo "$out"
  grep -q "status: Accepted" <<<"$out" || {
    local id; id="$(sed -n 's/^ *id: \(.*\)$/\1/p' <<<"$out" | head -1)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    echo "notarization failed for $1"; exit 1; }
}
DIST=build/dist; rm -rf "$DIST" build/dmg; mkdir -p "$DIST" build/dmg
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
notarize "$DIST/notarize.zip"
rm "$DIST/notarize.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"

# 5. Package the stapled app: zip for Sparkle, DMG (signed, notarized, stapled) for first installs.
ditto -c -k --keepParent "$APP" "$DIST/Plantty.zip"
cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname Plantty -srcfolder build/dmg -ov -format UDZO -fs APFS "$DIST/Plantty.dmg" -quiet
codesign --force --timestamp --sign "$DEVID" "$DIST/Plantty.dmg"
notarize "$DIST/Plantty.dmg"
xcrun stapler staple "$DIST/Plantty.dmg"

# 6. Sign the update archive with the EdDSA key from the login Keychain.
SIG=$("$SPARKLE_BIN/sign_update" "$DIST/Plantty.zip")   # sparkle:edSignature="…" length="…"

# 7. Commit the version bump, publish the GitHub release on that commit.
git commit -q -am "Release $VERSION"
git push -q origin main
{ cat "$NOTES"; printf '\n\nSHA-256:\n'; (cd "$DIST" && shasum -a 256 Plantty.dmg Plantty.zip | awk '{print "- `"$2"`: `"$1"`"}'); } > "$DIST/notes.md"
gh release create "v$VERSION" "$DIST/Plantty.dmg" "$DIST/Plantty.zip" --repo "$REPO" \
  --title "Plantty $VERSION" --notes-file "$DIST/notes.md" --target main

# 8. Announce it: newest item goes first in appcast.xml.
python3 - "$VERSION" "$BUILD" "$SIG" "$REPO" <<'PY'
import sys, email.utils, pathlib
version, build, sig, repo = sys.argv[1:]
path = pathlib.Path("appcast.xml")
item = f'''    <item>
      <title>Plantty {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/{repo}/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/{repo}/releases/download/v{version}/Plantty.zip" type="application/octet-stream" {sig.strip()}/>
    </item>
'''
text = path.read_text()
anchor = "    <title>Plantty</title>\n"
assert anchor in text, "unexpected appcast.xml layout"
path.write_text(text.replace(anchor, anchor + item, 1))
PY
git add appcast.xml
git commit -q -m "Appcast: Plantty $VERSION"
git push -q origin main
echo "Released $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/v$VERSION"
