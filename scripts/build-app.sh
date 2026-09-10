#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox
bash scripts/build-icon.sh
APP="$PWD/dist/PDFCopy.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PDFCopy "$APP/Contents/MacOS/PDFCopy"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
