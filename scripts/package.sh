#!/bin/bash
# Builds a distributable Mira.app, DMG and zip into dist/.
#
#   scripts/package.sh [version]          version defaults to MiraVersion in Support/Info.plist
#
# Environment:
#   SIGN_ID            codesign identity. Default "-" (ad-hoc). For public releases use
#                      "Developer ID Application: Name (TEAMID)".
#   NOTARY_PROFILE     notarytool keychain profile (xcrun notarytool store-credentials), or
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD   notarize with an app-specific password.
#                      Notarization runs only with a Developer ID identity.
#   BUILD_NUMBER       CFBundleVersion (default: git commit count)
#   ARCHS              default "arm64 x86_64" (universal)
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Support/Info.plist
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :MiraVersion' "$PLIST")}"
VERSION="${VERSION#v}"
SHORT_VERSION="${VERSION%%-*}"                       # 0.2.0-beta.1 -> 0.2.0
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_ID="${SIGN_ID:--}"
ARCHS="${ARCHS:-arm64 x86_64}"

BUILD=build
DIST=dist
APP="$BUILD/Mira.app"
DMG="$DIST/Mira-$VERSION.dmg"
ZIP="$DIST/Mira-$VERSION.zip"

echo "> Mira $VERSION (build $BUILD_NUMBER), archs: $ARCHS, signing: $SIGN_ID"
rm -rf "$APP" "$DIST"
mkdir -p "$BUILD" "$DIST"

# -- Build ----------------------------------------------------------------
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/Mira"
echo "> Binary: $(lipo -archs "$BIN"), $(vtool -show-build "$BIN" | grep -m1 minos | xargs)"

# -- Bundle ---------------------------------------------------------------
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mira"
cp "$PLIST" "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" \
                        -c "Set :CFBundleVersion $BUILD_NUMBER" \
                        -c "Set :MiraVersion $VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# -- Sign -----------------------------------------------------------------
SIGN_FLAGS=(--force --options runtime --entitlements entitlements.plist --sign "$SIGN_ID")
[ "$SIGN_ID" != "-" ] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# -- Package --------------------------------------------------------------
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Mira $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
[ "$SIGN_ID" != "-" ] && codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# -- Notarize (Developer ID only) -----------------------------------------
notarize() {
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" --wait
    fi
}
NOTARIZED=no
if [[ "$SIGN_ID" == Developer\ ID* ]] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${APPLE_ID:-}" ]; }; then
    echo "> Notarizing..."
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    # The app inside the DMG is covered by the DMG's ticket online; staple the
    # standalone copy too so the zip works offline.
    ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
    notarize "$BUILD/notarize.zip"
    rm "$BUILD/notarize.zip"
    xcrun stapler staple "$APP"
    NOTARIZED=yes
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# -- Checksums + Homebrew cask --------------------------------------------
(cd "$DIST" && shasum -a 256 "Mira-$VERSION.dmg" "Mira-$VERSION.zip" > SHA256SUMS.txt)
DMG_SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$DMG_SHA/g" packaging/homebrew/mira.rb.in > "$DIST/mira.rb"

echo
echo "> Done (notarized: $NOTARIZED)"
ls -lh "$DIST"
