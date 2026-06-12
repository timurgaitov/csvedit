#!/bin/bash
# Builds csvedit.app into ./build. Requires only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/csvedit.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -wmo -swift-version 5 \
    Sources/CSVTable.swift Sources/Document.swift Sources/EditorWindow.swift \
    Sources/AppDelegate.swift Sources/main.swift \
    -o "$APP/Contents/MacOS/csvedit" \
    -framework AppKit

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
