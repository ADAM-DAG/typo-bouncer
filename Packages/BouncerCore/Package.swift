// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BouncerCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "BouncerCore", targets: ["BouncerCore"])],
    targets: [
        .target(name: "BouncerCore"),
        .testTarget(name: "BouncerCoreTests", dependencies: ["BouncerCore"])
    ],
    swiftLanguageModes: [.v6]
)
