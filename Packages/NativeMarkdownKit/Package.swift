// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NativeMarkdownKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NativeMarkdownCore", targets: ["NativeMarkdownCore"]),
        .library(name: "NativeMarkdownAppKit", targets: ["NativeMarkdownAppKit"]),
        .executable(name: "NativeMarkdownDemo", targets: ["NativeMarkdownDemo"])
    ],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
    targets: [
        .target(name: "NativeMarkdownCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "NativeMarkdownAppKit", dependencies: ["NativeMarkdownCore"]),
        .executableTarget(name: "NativeMarkdownDemo", dependencies: ["NativeMarkdownAppKit"]),
        .testTarget(name: "NativeMarkdownCoreTests", dependencies: ["NativeMarkdownCore"]),
        .testTarget(name: "NativeMarkdownAppKitTests", dependencies: ["NativeMarkdownAppKit"])
    ]
)
