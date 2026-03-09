#!/bin/bash

set -euo pipefail

APP_NAME="Markdown Viewer"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BUILD_DIR="$SCRIPT_DIR/.build"
CACHE_DIR="$BUILD_DIR/cache"
DIST_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LICENSES_DIR="$RESOURCES_DIR/licenses"
VENDOR_DIR="$RESOURCES_DIR/vendor"
ICON_SOURCE="$SCRIPT_DIR/mdviewer.svg"
ICON_NAME="AppIcon"
ICON_PATH="$RESOURCES_DIR/$ICON_NAME.icns"

MARKED_VERSION="17.0.4"
MARKED_FILE="package/lib/marked.umd.js"
MARKED_SHA256="7e70d262692cda5ef9556bbe304a9fc2b3b9ca48e114688e5601eac6baac584a"

DOMPURIFY_VERSION="3.3.2"
DOMPURIFY_FILE="package/dist/purify.min.js"
DOMPURIFY_SHA256="d448d28fdc0e16a906823f0f4db4688288c159bf6b82dc37a48949db4231d380"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

extract_npm_file() {
    local package_name="$1"
    local version="$2"
    local archive_member="$3"
    local destination="$4"
    local expected_sha256="${5:-}"
    local archive_path="$CACHE_DIR/${package_name}-${version}.tgz"
    local archive_url="https://registry.npmjs.org/${package_name}/-/${package_name}-${version}.tgz"
    local temp_dir
    local actual_sha256

    mkdir -p "$CACHE_DIR"

    if [ ! -f "$archive_path" ]; then
        curl -fsSL "$archive_url" -o "$archive_path"
    fi

    temp_dir="$(mktemp -d)"
    tar -xzf "$archive_path" -C "$temp_dir" "$archive_member"

    if [ -n "$expected_sha256" ]; then
        actual_sha256="$(shasum -a 256 "$temp_dir/$archive_member" | awk '{print $1}')"
        if [ "$actual_sha256" != "$expected_sha256" ]; then
            rm -f "$archive_path"
            rm -rf "$temp_dir"
            printf 'Hash mismatch for %s@%s (%s)\n' "$package_name" "$version" "$archive_member" >&2
            exit 1
        fi
    fi

    cp "$temp_dir/$archive_member" "$destination"
    rm -rf "$temp_dir"
}

prepare_environment() {
    require_command bash
    require_command clang
    require_command curl
    require_command iconutil
    require_command plutil
    require_command sips
    require_command xcrun
    require_command shasum
    require_command tar

    mkdir -p "$DIST_DIR"
}

build_native_binary() {
    local sdk_path

    sdk_path="$(xcrun --show-sdk-path)"
    clang \
        -fobjc-arc \
        -Wall \
        -Wextra \
        -Wno-unused-parameter \
        -isysroot "$sdk_path" \
        -framework Cocoa \
        -framework CoreServices \
        -framework UniformTypeIdentifiers \
        -framework WebKit \
        "$SRC_DIR/main.m" \
        -o "$MACOS_DIR/MarkdownViewer"
}

rasterize_svg() {
    local svg_path="$1"
    local png_path="$2"
    local size="${3:-1024}"
    local sdk_path
    local helper_src
    local helper_bin

    sdk_path="$(xcrun --show-sdk-path)"
    helper_src="$(mktemp "${TMPDIR:-/tmp}/svg2png-XXXXXX.m")"
    helper_bin="${helper_src%.m}"

    cat > "$helper_src" <<'OBJC'
#import <AppKit/AppKit.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) return 1;
        NSString *input = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        NSInteger sz = atoi(argv[3]);
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:input];
        if (!img) return 1;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:sz pixelsHigh:sz
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = NSMakeSize(sz, sz);
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        [img drawInRect:NSMakeRect(0, 0, sz, sz)];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:output atomically:YES]) return 1;
    }
    return 0;
}
OBJC

    clang -fobjc-arc -isysroot "$sdk_path" -framework AppKit \
        "$helper_src" -o "$helper_bin"
    "$helper_bin" "$svg_path" "$png_path" "$size"
    rm -f "$helper_src" "$helper_bin"
}

build_app_icon() {
    local temp_dir
    local iconset_dir
    local source_png

    if [ ! -f "$ICON_SOURCE" ]; then
        printf 'App icon source not found: %s\n' "$ICON_SOURCE" >&2
        exit 1
    fi

    temp_dir="$(mktemp -d)"
    iconset_dir="$temp_dir/$ICON_NAME.iconset"
    source_png="$temp_dir/icon_1024.png"

    rasterize_svg "$ICON_SOURCE" "$source_png" 1024

    if [ ! -f "$source_png" ]; then
        rm -rf "$temp_dir"
        printf 'Could not rasterize %s into a PNG app icon.\n' "$ICON_SOURCE" >&2
        exit 1
    fi

    mkdir -p "$iconset_dir"

    sips -z 16 16 "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
    sips -z 32 32 "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
    sips -z 64 64 "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
    sips -z 256 256 "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
    sips -z 512 512 "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
    cp "$source_png" "$iconset_dir/icon_512x512@2x.png"

    iconutil -c icns "$iconset_dir" -o "$ICON_PATH"
    rm -rf "$temp_dir"
}

build_bundle() {
    echo "Building $APP_NAME..."

    prepare_environment

    rm -rf "$APP_DIR"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$VENDOR_DIR" "$LICENSES_DIR"

    build_native_binary
    build_app_icon
    cp "$SRC_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
    cp "$SRC_DIR/MarkdownViewer.sh" "$RESOURCES_DIR/MarkdownViewer.sh"
    cp "$SRC_DIR/viewer.css" "$RESOURCES_DIR/viewer.css"
    cp "$SRC_DIR/viewer.js" "$RESOURCES_DIR/viewer.js"
    cp "$SCRIPT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"

    extract_npm_file "marked" "$MARKED_VERSION" "$MARKED_FILE" "$VENDOR_DIR/marked.umd.js" "$MARKED_SHA256"
    extract_npm_file "marked" "$MARKED_VERSION" "package/LICENSE.md" "$LICENSES_DIR/marked-LICENSE.md"
    extract_npm_file "dompurify" "$DOMPURIFY_VERSION" "$DOMPURIFY_FILE" "$VENDOR_DIR/purify.min.js" "$DOMPURIFY_SHA256"
    extract_npm_file "dompurify" "$DOMPURIFY_VERSION" "package/LICENSE" "$LICENSES_DIR/dompurify-LICENSE"

    chmod 755 "$RESOURCES_DIR/MarkdownViewer.sh"
    plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
    bash -n "$RESOURCES_DIR/MarkdownViewer.sh"

    if command -v codesign >/dev/null 2>&1; then
        if ! codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1; then
            printf 'Warning: ad-hoc codesign failed; continuing with unsigned bundle.\n' >&2
        elif ! codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
            printf 'Warning: codesign verification failed; continuing with bundle as built.\n' >&2
        fi
    fi

    echo "Done! Built -> $APP_DIR"
}

clean_outputs() {
    rm -rf "$DIST_DIR"
    echo "Removed $DIST_DIR"
}

if [ "${1:-}" = "clean" ]; then
    clean_outputs
else
    build_bundle
fi
