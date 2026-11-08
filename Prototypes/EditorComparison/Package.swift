// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EditorComparison",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Vendor/swift-markdown-engine")],
    targets: [
        .executableTarget(
            name: "EditorComparison",
            dependencies: [.product(name: "MarkdownEngine", package: "swift-markdown-engine")],
            resources: [.copy("Web")]
        )
    ]
)
