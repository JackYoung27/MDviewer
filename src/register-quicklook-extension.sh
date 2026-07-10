#!/bin/bash
# Registers the Quick Look extension with PluginKit and elects it as the
# preferred previewer for Markdown files, overriding any other Quick Look
# extension currently handling them (e.g. QLMarkdown). Runs as the target
# user. Usage: register-quicklook-extension.sh "/Applications/Markdown Viewer.app"

set -euo pipefail

APP_PATH="${1:?usage: register-quicklook-extension.sh /path/to/Markdown Viewer.app}"
APPEX_PATH="$APP_PATH/Contents/PlugIns/MarkdownViewerQuickLook.appex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

"$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
pluginkit -a "$APPEX_PATH" >/dev/null 2>&1 || true
pluginkit -e use -i com.local.markdown-viewer.quicklook >/dev/null 2>&1
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "Quick Look extension elected: com.local.markdown-viewer.quicklook"
