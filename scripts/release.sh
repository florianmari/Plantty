#!/usr/bin/env bash
# Publishes a Plantty release and announces it to Sparkle.
# usage: scripts/release.sh <version> <notes.md>     e.g. scripts/release.sh 0.1.2 notes.md
#
# Order matters: the GitHub release (with its files) goes up before appcast.xml is pushed,
# so the updater never offers a download that doesn't exist yet.
set -euo pipefail

VERSION="${1:?version, e.g. 0.1.2}"
NOTES="${2:?release notes markdown file}"
REPO="florianmari/Plantty"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -f "$NOTES" ]] || { echo "notes file not found: $NOTES"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean; commit first"; exit 1; }
git fetch -q origin && [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not in sync with origin/main"; exit 1; }
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && { echo "v$VERSION already exists"; exit 1; }

# 1. Bump version; the build number must always grow, Sparkle compares it.
BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

# 2. Build, test, package.
xcodegen generate -q
xcodebuild -project Plantty.xcodeproj -scheme Plantty -derivedDataPath build test -quiet
xcodebuild -project Plantty.xcodeproj -scheme Plantty -configuration Release -derivedDataPath build build -quiet
APP=build/Build/Products/Release/Plantty.app
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]

DIST=build/dist; rm -rf "$DIST" build/dmg; mkdir -p "$DIST" build/dmg
ditto -c -k --keepParent "$APP" "$DIST/Plantty.zip"
cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname Plantty -srcfolder build/dmg -ov -format UDZO -fs APFS "$DIST/Plantty.dmg" -quiet

# 3. Sign the update archive with the EdDSA key from the login Keychain.
SIG=$(build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update "$DIST/Plantty.zip")   # sparkle:edSignature="…" length="…"

# 4. Commit the version bump, publish the GitHub release on that commit.
git commit -q -am "Release $VERSION"
git push -q origin main
{ cat "$NOTES"; printf '\n\nSHA-256:\n'; (cd "$DIST" && shasum -a 256 Plantty.dmg Plantty.zip | awk '{print "- `"$2"`: `"$1"`"}'); } > "$DIST/notes.md"
gh release create "v$VERSION" "$DIST/Plantty.dmg" "$DIST/Plantty.zip" --repo "$REPO" \
  --title "Plantty $VERSION" --notes-file "$DIST/notes.md" --target main

# 5. Announce it: newest item goes first in appcast.xml.
python3 - "$VERSION" "$BUILD" "$SIG" "$REPO" <<'PY'
import sys, email.utils, pathlib
version, build, sig, repo = sys.argv[1:]
path = pathlib.Path("appcast.xml")
if not path.exists():
    path.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
                    '  <channel>\n    <title>Plantty</title>\n  </channel>\n</rss>\n')
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
