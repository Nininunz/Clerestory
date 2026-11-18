// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClerestoryModuleCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "ClerestoryModuleCore",
            targets: ["ClerestoryModuleCore"]
        ),
    ],
    targets: [
        .target(name: "ClerestoryModuleCore"),
        .testTarget(
            name: "ClerestoryModuleCoreTests",
            dependencies: ["ClerestoryModuleCore"]
        ),
    ]
)
