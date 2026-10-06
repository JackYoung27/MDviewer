#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/build.sh"
TEST_APP="$ROOT/.build/PreviewTests.app"
rm -rf "$TEST_APP"
mkdir -p "$TEST_APP/Contents/MacOS"
cp "$ROOT/dist/Markdown Viewer.app/Contents/Info.plist" "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.local.markdown-viewer.tests' "$TEST_APP/Contents/Info.plist"
ditto "$ROOT/dist/Markdown Viewer.app/Contents/Resources" "$TEST_APP/Contents/Resources"
clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=15.0 \
    -framework Cocoa -framework CoreServices -framework UniformTypeIdentifiers -framework WebKit \
    "$ROOT/tests/preview.m" -o "$TEST_APP/Contents/MacOS/MarkdownViewer"
"$TEST_APP/Contents/MacOS/MarkdownViewer"
