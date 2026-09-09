#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --cache-path "$PWD/.build/cache"
BIN="$(swift build --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache")"
swiftc -swift-version 5 -D SESSION_TEST -I "$BIN/Modules" \
  Sources/HeadphoneBar/*.swift Tests/HeadphoneBarTests/SessionTests.swift \
  "$BIN"/HeadphoneProtocol.build/*.swift.o \
  "$BIN"/MomentumCore.build/*.swift.o \
  "$BIN"/MomentumBluetooth.build/*.swift.o \
  -o "$BIN/HeadphoneSessionTests"
"$BIN/HeadphoneSessionTests"
