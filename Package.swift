// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AudioPluginManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AudioPluginManager", targets: ["AudioPluginManager"])
    ],
    targets: [
        .executableTarget(
            name: "AudioPluginManager",
            path: "Sources/AudioPluginManager"
        )
    ]
)
