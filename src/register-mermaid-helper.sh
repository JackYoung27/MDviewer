#!/bin/bash
# Registers the on-demand Mermaid render helper as a per-user launchd agent.
# Runs as the target user. Usage: register-mermaid-helper.sh "/Applications/Markdown Viewer.app"

set -euo pipefail

APP_PATH="${1:?usage: register-mermaid-helper.sh /path/to/Markdown Viewer.app}"
AGENT_LABEL="com.local.markdown-viewer.render-helper"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_PATH/Contents/MacOS/MarkdownViewerRenderHelper</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>$AGENT_LABEL</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || \
    launchctl load "$AGENT_PLIST" >/dev/null 2>&1 || \
    { printf 'Could not register the mermaid render helper agent.\n' >&2; exit 1; }
echo "render helper agent -> $AGENT_PLIST"
