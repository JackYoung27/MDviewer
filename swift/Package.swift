// swift-tools-version: 5.10
import PackageDescription

// Swift port of MDviewer. `swift/build.sh` compiles these targets and swaps
// them into the bundle produced by the root build.sh, which continues to own
// resources, vendored libraries, plists, and signing.
let package = Package(
    name: "MarkdownViewer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "RenderHelperKit",
            path: "Sources/RenderHelperKit"
        ),
        .executableTarget(
            name: "MarkdownViewerApp",
            dependencies: ["RenderHelperKit"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "QuickLookPreview",
            dependencies: ["RenderHelperKit"],
            path: "Sources/QuickLookPreview",
            linkerSettings: [
                // App extensions enter through NSExtensionMain, not main.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        .executableTarget(
            name: "RenderHelper",
            dependencies: ["RenderHelperKit"],
            path: "Sources/RenderHelper"
        ),
    ]
)
