#!/bin/sh
# Release: Developer ID build -> notarise -> staple -> DMG in site/public/.
# Needs the "Developer ID Application: Omar Maroki" cert and a notarytool keychain profile.
set -e
cd "$(dirname "$0")"
SIGN_ID="${SIGN_ID:-Developer ID Application: Omar Maroki (S34Q66469Q)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
export SIGN_ID
./build.sh
APP=build/Juice.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Notarising $VERSION"
ditto -c -k --keepParent "$APP" build/Juice.zip
NOTARISED=1
if xcrun notarytool submit build/Juice.zip --keychain-profile "$NOTARY_PROFILE" --wait | tee build/notary.log | grep -q "status: Accepted"; then
  xcrun stapler staple "$APP"
else
  NOTARISED=0
  echo "!! Not notarised (see build/notary.log). Fix with:"
  echo "   xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id S34Q66469Q"
fi
rm -rf /Applications/Juice.app && cp -R "$APP" /Applications/

echo "==> DMG"
STAGE=build/dmg && rm -rf "$STAGE" && mkdir "$STAGE"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
mkdir -p site/public
rm -f site/public/Juice.dmg
hdiutil create -volname "Juice" -srcfolder "$STAGE" -ov -format UDZO site/public/Juice.dmg >/dev/null
codesign --force --timestamp -s "$SIGN_ID" site/public/Juice.dmg
if [ "$NOTARISED" = 1 ]; then
  xcrun notarytool submit site/public/Juice.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple site/public/Juice.dmg
  echo "Released Juice $VERSION (notarised) -> site/public/Juice.dmg"
else
  echo "Built Juice $VERSION (signed, NOT notarised) -> site/public/Juice.dmg"
fi
