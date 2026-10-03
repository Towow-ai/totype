// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VerbatimVoiceCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VerbatimCore", targets: ["VerbatimCore"])
    ],
    targets: [
        .target(name: "VerbatimCore"),
        .testTarget(name: "VerbatimCoreTests", dependencies: ["VerbatimCore"])
    ]
)
