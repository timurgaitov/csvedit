#!/bin/bash
# Runs the engine tests (pure logic + perf benchmark) and the in-process UI
# integration tests. The UI tests briefly create real windows on screen.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build/test build/uitest

echo "=== engine tests ==="
cp test/engine_test.swift build/test/main.swift
swiftc -O -swift-version 5 \
    Sources/CSVTable.swift Sources/Document.swift \
    build/test/main.swift -o build/engine_test
./build/engine_test

echo
echo "=== ui tests ==="
cp test/ui_test.swift build/uitest/main.swift
swiftc -swift-version 5 \
    Sources/CSVTable.swift Sources/Document.swift Sources/EditorWindow.swift \
    build/uitest/main.swift -o build/ui_test
./build/ui_test
