// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FileExplorer"),
        .testTarget(name: "FileExplorerTests", dependencies: ["FileExplorer"]),
    ],
    swiftLanguageModes: [.v5]
)
