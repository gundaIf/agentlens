// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentLens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentLens", path: "Sources/AgentLens")
    ]
)
