#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project PDFCopy.xcodeproj -scheme PDFCopyIOS \
    -sdk iphonesimulator -configuration Debug -derivedDataPath .build/ios \
    CODE_SIGNING_ALLOWED=NO build
