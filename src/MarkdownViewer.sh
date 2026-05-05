#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TMP_ROOT="${TMPDIR:-/tmp}"
PREVIEW_ROOT="${MARKDOWN_VIEWER_OUTPUT_DIR:-${TMP_ROOT%/}/markdown-viewer-previews}"

require_resource() {
    if [ ! -e "$1" ]; then
        printf '%s is missing from the app bundle. Rebuild the app and try again.\n' "$2" >&2
        exit 1
    fi
}

to_file_url() {
    local resolved
    resolved="$(cd "$1" && pwd)"
    printf 'file://%s' "$resolved"
}

encode_file_base64() {
    /usr/bin/base64 < "$1" | tr -d '\n'
}

encode_string_base64() {
    printf '%s' "$1" | /usr/bin/base64 | tr -d '\n'
}

safe_preview_stem() {
    local stem="${1%.*}"
    stem="$(printf '%s' "$stem" | tr -cs 'A-Za-z0-9._-' '-')"
    printf '%s' "${stem:-preview}"
}

prepare_preview_dir() {
    local preview_dir="$1"

    mkdir -p "$preview_dir"
    ln -s "$RESOURCES_DIR/viewer.css" "$preview_dir/viewer.css"
    ln -s "$RESOURCES_DIR/viewer.js" "$preview_dir/viewer.js"
    ln -s "$RESOURCES_DIR/vendor" "$preview_dir/vendor"
}

render_preview() {
    local input_file="$1"
    local filename="$2"
    local preview_dir="$3"
    local html_path="$preview_dir/index.html"
    local source_path base_url

    source_path="$(cd "$(dirname "$input_file")" && pwd)/$(basename "$input_file")"
    base_url="$(to_file_url "$(dirname "$source_path")")"
    [ "${base_url%/}" = "$base_url" ] && base_url="$base_url/"

    cat > "$html_path" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri file:; img-src data: file: http: https:; media-src data: file: http: https:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'none'; font-src data: file:; object-src 'none'; frame-src 'none'; form-action 'none';">
<meta name="color-scheme" content="light dark">
<title>Markdown Viewer</title>
<link rel="stylesheet" href="vendor/katex.min.css">
<link rel="stylesheet" href="viewer.css">
</head>
<body>
<main class="document" id="content" aria-live="polite">
  <p class="document__status">Rendering preview...</p>
</main>

<script id="viewer-data" type="application/json">
{"filename":"$(encode_string_base64 "$filename")","sourcePath":"$(encode_string_base64 "$source_path")","baseUrl":"$(encode_string_base64 "$base_url")","markdown":"$(encode_file_base64 "$input_file")"}
</script>
<script src="vendor/marked.umd.js"></script>
<script src="vendor/purify.min.js"></script>
<script src="vendor/mermaid.min.js"></script>
<script src="vendor/katex.min.js"></script>
<script src="vendor/katex-auto-render.min.js"></script>
<script src="viewer.js"></script>
</body>
</html>
HTML

    printf '%s\n' "$html_path"
}

cleanup_old_previews() {
    mkdir -p "$PREVIEW_ROOT"
    local marker="$PREVIEW_ROOT/.last_cleanup"
    if [ -f "$marker" ] && [ "$(find "$marker" -mtime -1 2>/dev/null)" ]; then
        return
    fi
    find "$PREVIEW_ROOT" -mindepth 1 -not -name '.last_cleanup' -mtime +7 -delete 2>/dev/null || true
    touch "$marker"
}

main() {
    local rendered=0

    require_resource "$RESOURCES_DIR/viewer.css" "viewer.css"
    require_resource "$RESOURCES_DIR/viewer.js" "viewer.js"
    require_resource "$RESOURCES_DIR/vendor/marked.umd.js" "marked.umd.js"
    require_resource "$RESOURCES_DIR/vendor/purify.min.js" "purify.min.js"
    require_resource "$RESOURCES_DIR/vendor/mermaid.min.js" "mermaid.min.js"
    require_resource "$RESOURCES_DIR/vendor/katex.min.css" "katex.min.css"
    require_resource "$RESOURCES_DIR/vendor/katex.min.js" "katex.min.js"
    require_resource "$RESOURCES_DIR/vendor/katex-auto-render.min.js" "katex-auto-render.min.js"
    require_resource "$RESOURCES_DIR/vendor/fonts" "KaTeX fonts"

    cleanup_old_previews

    local arg
    for arg in "$@"; do
        case "$arg" in -psn_*) continue ;; esac

        if [ ! -f "$arg" ] || [ ! -r "$arg" ]; then
            printf 'Skipping: %s\n' "$arg" >&2
            continue
        fi

        local filename preview_name preview_dir
        filename="$(basename "$arg")"
        preview_name="$(safe_preview_stem "$filename")"
        preview_dir="$(mktemp -d "$PREVIEW_ROOT/${preview_name}-XXXXXX")"
        prepare_preview_dir "$preview_dir"
        render_preview "$arg" "$filename" "$preview_dir"
        rendered=1
    done

    [ "$rendered" -eq 1 ] || exit 1
}

main "$@"
