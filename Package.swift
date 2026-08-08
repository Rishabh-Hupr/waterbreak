// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WaterBreak",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "WaterBreak", path: "Sources/WaterBreak")
    ]
)
