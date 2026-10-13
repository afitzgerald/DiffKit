// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiffKit",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "DiffKit", targets: ["DiffKit"]),
    ],
    targets: [
        .target(name: "DiffKit",
                // mermaid.js 11.12.1 (MIT), for ```mermaid blocks in MarkdownView. Copied, so the
                // page finds the script next to it.
                resources: [.copy("Resources/mermaid.html"), .copy("Resources/mermaid.min.js"),
                            .copy("Resources/mermaid-LICENSE.txt")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "diffkit-selfcheck", dependencies: ["DiffKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Local UI harness; not a product, so nothing that depends on DiffKit builds it.
        .executableTarget(name: "diffkit-preview", dependencies: ["DiffKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
