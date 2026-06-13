// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IslandRadio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "IslandRadio",
            path: "src",
            resources: [.copy("Resources")]
        ),
    ]
)
