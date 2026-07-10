<p align="center">
  <img src="./assets/mdviewer.svg" alt="MDviewer logo" width="128">
</p>

<h1 align="center">MDviewer</h1>

<p align="center">
  Markdown previews are usually cluttered, browser-based, or tied to editors.<br>
  MDviewer is a tiny native macOS app that opens any Markdown file as a clean, print-ready document.
</p>

<p align="center">
  <a href="https://github.com/JackYoung27/mdviewer/releases/latest">Download</a>
  &nbsp;&middot;&nbsp;
  <a href="#features">Features</a>
  &nbsp;&middot;&nbsp;
  <a href="#install">Install</a>
</p>

---

<p align="center">
  <img src="./assets/demo.gif" alt="MDviewer demo" width="720">
</p>

## Why MDviewer?

Most Markdown previews are inside editors or browsers.

MDviewer is different:
- Double-click a Markdown file and read it immediately
- Clean typography optimized for printing
- No Electron, no runtime dependencies
- Fully local and secure

## Features

- **Native macOS** — Cocoa + WKWebView, launches instantly, under 1 MB
- **Print-ready typography** — serif body, clean headings, proper spacing
- **PDF export** — `Cmd+Shift+E` to save, `Cmd+P` to print
- **In-document search** — `Cmd+F` finds text in the rendered Markdown, with next/previous match navigation
- **Live reload** — re-renders automatically when the file changes on disk
- **GitHub Flavored Markdown** — tables, task lists, fenced code blocks
- **Mermaid diagrams** — renders fenced `mermaid` diagrams inline, fully local
- **LaTeX math** — renders inline `$...$` and block `$$...$$` math with bundled KaTeX
- **Dark mode** — the app and Quick Look previews follow your macOS appearance setting, including Mermaid diagrams (rendered and cached in both themes)
- **Secure** — HTML sanitized with [DOMPurify](https://github.com/cure53/DOMPurify), strict Content Security Policy
- **Finder integration** — registers as default `.md` handler; double-click to open
- **Quick Look** — press Space on a Markdown file in Finder for a fully rendered preview: tables, code, task lists, images, LaTeX math, and Mermaid diagrams (from the app's render cache — or live everywhere with the optional `--with-mermaid-helper` install flag)
- **Font settings** — pick the document font in Settings (`Cmd+,`): Serif (default), GitHub, or Geist (the Next.js font, bundled)
- **Tabbed windows** — multiple documents in one window
- **Local-first** — no telemetry, no accounts, and no network calls except the update check you trigger yourself from the menu

## Install

### Download

1. Grab `Markdown-Viewer-macOS.zip` from [Releases](https://github.com/JackYoung27/mdviewer/releases/latest)
2. Unzip, drag to `/Applications`
3. On first launch, macOS will block the app because it's unsigned. To open it:
   - **Right-click** (or Control-click) the app → click **Open** → click **Open** again in the dialog
   - Or run in Terminal: `xattr -cr /Applications/Markdown\ Viewer.app`
4. After the first open, it launches normally like any other app

### Build from source

```bash
git clone https://github.com/JackYoung27/mdviewer.git
cd mdviewer
./build.sh            # builds to dist/Markdown Viewer.app
./build.sh installer  # builds dist/Markdown-Viewer-Installer.pkg — a standard
                      # macOS installer with checkboxes for "default .md viewer"
                      # and the optional Mermaid Quick Look helper
./install.sh          # CLI alternative: copies to /Applications and sets as
                      # default handler; add --with-mermaid-helper for live
                      # Mermaid in Quick Look
```

## Permissions

Designed to be inspectable and minimal:

- The app makes **no network requests on its own** — "Check for Updates…" in the menu is the only network call, and only when you click it.
- The Quick Look extension is **sandboxed** with read-only filesystem access (so previews can load images your markdown references — wherever the file lives — and the diagram cache). It cannot write anything. macOS additionally asks once before it can read images in privacy-protected folders like Desktop or Documents.
- **No background processes by default.** The optional Mermaid helper (only if you install with `--with-mermaid-helper`) appears under Login Items as a background item; launchd spawns it on demand and it exits after 45 seconds idle. Remove it anytime: `launchctl bootout gui/$(id -u)/com.local.markdown-viewer.render-helper && rm ~/Library/LaunchAgents/com.local.markdown-viewer.render-helper.plist`
- All vendored libraries (marked, DOMPurify, Mermaid, KaTeX, Geist) are downloaded from npm at build time and verified against pinned SHA-256 hashes.

Requires Xcode Command Line Tools (`xcode-select --install`).

## Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| Open file | `Cmd+O` |
| Settings | `Cmd+,` |
| Find in document | `Cmd+F` |
| Next match | `Cmd+G` |
| Previous match | `Cmd+Shift+G` |
| Reload | `Cmd+R` |
| Print | `Cmd+P` |
| Export PDF | `Cmd+Shift+E` |
| Close window | `Cmd+W` |

## Screenshots

| Document view | Code blocks | Checklists |
|---|---|---|
| ![doc](./assets/screenshot-doc.png) | ![code](./assets/screenshot-code.png) | ![checklist](./assets/screenshot-checklist.png) |

## License

[MIT](./LICENSE)
