// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ada",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Ada", path: "Sources")]
)
