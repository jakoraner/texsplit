// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TeXSplit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TeXSplit", path: "Sources/TeXSplit")
    ]
)
