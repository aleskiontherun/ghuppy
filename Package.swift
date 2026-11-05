// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ghuppy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ghuppy", targets: ["Ghuppy"]),
    ],
    targets: [
        .target(name: "GhuppyCore"),
        .executableTarget(name: "Ghuppy", dependencies: ["GhuppyCore"]),
        .testTarget(name: "GhuppyCoreTests", dependencies: ["GhuppyCore"]),
    ]
)
