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
ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_ARGS=(--arch arm64 --arch x86_64); fi
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" "${ARCH_ARGS[@]}"
BINARY_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache" "${ARCH_ARGS[@]}")"
APP="$PWD/dist/HeadphoneBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIR/HeadphoneBar" "$APP/Contents/MacOS/HeadphoneBar"
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
