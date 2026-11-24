#!/bin/sh
# Builds Juice.app into build/ and copies it to /Applications.
set -e
cd "$(dirname "$0")"
APP=build/Juice.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -O2 -Wall -o "$APP/Contents/Resources/juice-helper" helper/juice-helper.c -framework IOKit -framework CoreFoundation
cp helper/install-helper.sh "$APP/Contents/Resources/"

clang -O2 -c App/smc.c -o build/smc.o
swiftc -O -parse-as-library -import-objc-header App/smc.h build/smc.o -target arm64-apple-macos14 -o "$APP/Contents/MacOS/Juice" App/*.swift -lIOReport

# App icon: drawn by the app itself, then packed into an .icns
"$APP/Contents/MacOS/Juice" --appicon build/icon.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Juice</string>
  <key>CFBundleIdentifier</key><string>com.omar.juice</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Juice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP"
rm -rf /Applications/Juice.app
cp -R "$APP" /Applications/
echo "Built and installed /Applications/Juice.app"
