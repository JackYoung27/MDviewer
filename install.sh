#!/bin/bash

set -euo pipefail

APP_NAME="Markdown Viewer.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_APP="$SCRIPT_DIR/dist/$APP_NAME"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LAUNCH_SERVICES_PLIST="$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

# Registers the on-demand mermaid render helper with launchd. The agent owns
# no running process at rest; launchd spawns it when the Quick Look extension
# connects and it exits itself when idle.
install_render_helper_agent() {
    "$TARGET_APP/Contents/Resources/register-mermaid-helper.sh" "$TARGET_APP" || \
        printf 'Warning: could not register the mermaid render helper agent.\n' >&2
}

usage() {
    cat <<'EOF'
Usage:
  ./install.sh                        Install the app and set it as default .md handler
  ./install.sh --with-mermaid-helper  Also register the optional background helper that
                                      renders Mermaid diagrams live in Quick Look
                                      (appears under System Settings > Login Items)
EOF
}

main() {
    local with_mermaid_helper=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --with-mermaid-helper)
                with_mermaid_helper=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 1
                ;;
        esac
    done

    require_command ditto
    require_command plutil
    require_command python3

    "$SCRIPT_DIR/build.sh"

    if [ ! -d "$DIST_APP" ]; then
        printf 'Built app not found at %s\n' "$DIST_APP" >&2
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    # A stale bundle merged over breaks the code-signature seal; replace cleanly.
    rm -rf "$TARGET_APP"
    ditto "$DIST_APP" "$TARGET_APP"
    "$LSREGISTER" -f "$TARGET_APP" >/dev/null

    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")"

    python3 "$TARGET_APP/Contents/Resources/set-default-handler.py" "$bundle_id" "$LAUNCH_SERVICES_PLIST"

    "$LSREGISTER" -kill -seed -r -domain local -domain system -domain user >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$TARGET_APP" >/dev/null

    # Elect our Quick Look extension over any other Markdown previewer
    # (e.g. QLMarkdown) already registered for the same file types.
    "$TARGET_APP/Contents/Resources/register-quicklook-extension.sh" "$TARGET_APP" || \
        printf 'Warning: could not elect the Quick Look extension.\n' >&2

    if [ "$with_mermaid_helper" -eq 1 ]; then
        install_render_helper_agent
    else
        echo "Mermaid diagrams render in Quick Look after a file is opened in the app once."
        echo "For live rendering of never-opened diagrams, re-run with --with-mermaid-helper."
    fi

    killall cfprefsd Finder >/dev/null 2>&1 || true

    echo "Installed -> $TARGET_APP"
}

main "$@"
