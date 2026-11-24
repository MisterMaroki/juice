#!/bin/sh
# Builds Juice.app into build/ and copies it to /Applications.
set -e
cd "$(dirname "$0")"
APP=build/Juice.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -O2 -Wall -o "$APP/Contents/Resources/juice-helper" helper/juice-helper.c -framework IOKit -framework CoreFoundation
cp helper/install-helper.sh "$APP/Contents/Resources/"

swiftc -O -parse-as-library -target arm64-apple-macos14 -o "$APP/Contents/MacOS/Juice" App/*.swift

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Juice</string>
  <key>CFBundleIdentifier</key><string>com.omar.juice</string>
  <key>CFBundleExecutable</key><string>Juice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
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
