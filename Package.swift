// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sapu",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "sapu", targets: ["sapu"]),
        .library(name: "SapuCore", targets: ["SapuCore"]),
    ],
    targets: [
        .target(name: "SapuCore"),
        .executableTarget(name: "sapu", dependencies: ["SapuCore"]),
        .testTarget(name: "SapuCoreTests", dependencies: ["SapuCore"]),
    ]
)
