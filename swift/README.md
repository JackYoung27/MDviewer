# Swift port

A port of MDviewer to Swift + SwiftUI — Apple's recommended stack for new
native apps. Built as a Swift Package (buildable with Command Line Tools
alone, no Xcode required), preserving this repo's script-driven ethos.

```bash
./swift/build.sh    # builds the Swift targets and swaps them into the bundle
                    # produced by the root build.sh -> dist/Markdown Viewer.app
```

## Architecture

| Target | Replaces | Notes |
|---|---|---|
| `MarkdownViewerApp` | `src/main.m` | SwiftUI `DocumentGroup` lifecycle (open panel, recents, window-per-document for free), `PreviewModel` owns the WKWebView + renderer pipeline |
| `QuickLookPreview` | `src/quicklook.m` | Same data-based `QLPreviewProvider`, JavaScriptCore marked + KaTeX, cid: image attachments, mermaid cache + XPC |
| `RenderHelper` | `src/render-helper.m` | Same on-demand launchd agent contract |
| `RenderHelperKit` | `src/render-helper.h` | Shared XPC protocol — `@objc` names match the ObjC build, so Swift and ObjC components interoperate |

The root `build.sh` still owns bundle layout, vendored libraries (pinned
SHA-256), plists, entitlements, and signing; `swift/build.sh` swaps the three
Mach-O binaries. `viewer.js` / `viewer.css` are shared unchanged — they are
the app's rendering identity regardless of native language.

Cache compatibility is verified: the Swift app writes mermaid SVGs with
byte-identical hashes to the ObjC build, and either extension can read either
app's cache.

## Parity status

Ported and verified: render pipeline (via `MarkdownViewer.sh`), live reload
with scroll restore, font settings (same `MDVPreferredFont` default), find /
print / PDF export / reveal / dark-mode toggle, manual update check, full
Quick Look extension (tables, code, math, images, mermaid), render helper.

Known gaps / TODOs:

- Window tabbing preference is not exposed by SwiftUI (`NSWindow.tabbingMode`);
  windows can still be tabbed manually.
- Swift 5 language mode; migrate to Swift 6 strict concurrency.
- For Mac App Store submission, wrap these sources in an Xcode project (needed
  for provisioning/app groups); the sources are the hard part and carry over.
- "Open PDF in Default App" writes to the temporary directory rather than the
  preview staging directory.
