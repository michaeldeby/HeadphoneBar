#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export UNIVERSAL=1
./scripts/build-app.sh
RELEASE_VERSION="$(cat VERSION)"
RELEASE_DIR="$PWD/dist/release"
mkdir -p "$RELEASE_DIR"
BASE="HeadphoneBar-${RELEASE_VERSION}-macOS-universal"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent dist/HeadphoneBar.app "$RELEASE_DIR/$BASE.zip"
/usr/bin/pkgbuild --component dist/HeadphoneBar.app --install-location /Applications \
  --identifier com.michaeldeby.headphonebar.installer --version "$RELEASE_VERSION" \
  "$RELEASE_DIR/$BASE.pkg"
(cd "$RELEASE_DIR" && shasum -a 256 "$BASE.zip" "$BASE.pkg" > SHA256SUMS.txt)
echo "Release artifacts: $RELEASE_DIR"
