#!/bin/bash
# Builds the Swift port and swaps its binaries into the app bundle produced by
# the root build.sh, which continues to own resources, vendored libraries,
# plists, entitlements, and bundle layout.

set -euo pipefail

SWIFT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SWIFT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Markdown Viewer.app"
APPEX_DIR="$APP_DIR/Contents/PlugIns/MarkdownViewerQuickLook.appex"

echo "Building ObjC bundle scaffold..."
"$ROOT_DIR/build.sh" build

echo "Building Swift targets..."
cd "$SWIFT_DIR"
swift build -c release

BIN="$SWIFT_DIR/.build/release"

echo "Swapping in Swift binaries..."
cp "$BIN/MarkdownViewerApp" "$APP_DIR/Contents/MacOS/MarkdownViewer"
cp "$BIN/QuickLookPreview" "$APPEX_DIR/Contents/MacOS/MarkdownViewerQuickLook"
cp "$BIN/RenderHelper" "$APP_DIR/Contents/MacOS/MarkdownViewerRenderHelper"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --entitlements "$ROOT_DIR/src/quicklook.entitlements" "$APPEX_DIR"
    codesign --force --sign - "$APP_DIR/Contents/MacOS/MarkdownViewerRenderHelper"
    codesign --force --sign - "$APP_DIR"
fi

echo "Done! Swift-powered bundle -> $APP_DIR"

# "installer" also wraps the Swift bundle in the .pkg wizard.
if [ "${1:-build}" = "installer" ]; then
    echo "Building installer around the Swift bundle..."
    MDV_SKIP_BUILD=1 "$ROOT_DIR/build.sh" installer
fi
