// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ghuppy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ghuppy", targets: ["Ghuppy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(name: "GhuppyCore", dependencies: ["Yams"]),
        .executableTarget(name: "Ghuppy", dependencies: ["GhuppyCore"]),
        .testTarget(name: "GhuppyCoreTests", dependencies: ["GhuppyCore"]),
    ]
)
