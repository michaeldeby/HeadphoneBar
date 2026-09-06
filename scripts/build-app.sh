#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" .build/cache
BUILD_VERSION="$(cat VERSION)"
if [[ ! "$BUILD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain a numeric major.minor.patch version" >&2
  exit 1
fi
APP="$PWD/dist/HeadphoneBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  for arch in arm64 x86_64; do
    triple="${arch}-apple-macosx14.0"
    swift build -c release --product HeadphoneBar --triple "$triple" --disable-sandbox --cache-path "$PWD/.build/cache"
    binary_dir="$(swift build -c release --show-bin-path --triple "$triple" --disable-sandbox --cache-path "$PWD/.build/cache")"
    cp "$binary_dir/HeadphoneBar" "$PWD/.build/HeadphoneBar-$arch"
  done
  lipo -create "$PWD/.build/HeadphoneBar-arm64" "$PWD/.build/HeadphoneBar-x86_64" -output "$APP/Contents/MacOS/HeadphoneBar"
else
  swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
  BINARY_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache")"
  cp "$BINARY_DIR/HeadphoneBar" "$APP/Contents/MacOS/HeadphoneBar"
fi
cp -R ThirdPartyNotices "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>HeadphoneBar</string>
<key>CFBundleDisplayName</key><string>HeadphoneBar</string>
<key>CFBundleIdentifier</key><string>local.headphonebar.app</string>
<key>CFBundleExecutable</key><string>HeadphoneBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>HeadphoneBar connects to your paired headphones to read battery and adjust noise control and equalizer settings.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>HeadphoneBar uses Bluetooth to adjust your headphones.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUILD_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
