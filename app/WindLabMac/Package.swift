// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "WindLabMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WindLabMac", targets: ["WindLabMac"])
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "WindogCore", dependencies: ["CZlib"]),
        .executableTarget(
            name: "WindLabMac",
            dependencies: ["WindogCore"]
        ),
        .testTarget(name: "WindogCoreTests", dependencies: ["WindogCore"]),
        .testTarget(name: "WindLabMacTests", dependencies: ["WindLabMac", "WindogCore"])
    ]
)
