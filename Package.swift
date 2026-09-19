// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Photozen",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Photozen",
            path: "Sources/Photozen"
        )
    ]
)
