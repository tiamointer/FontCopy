// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FontCopy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FontCopy", targets: ["FontCopy"]),
        .library(name: "FontCopyCore", targets: ["FontCopyCore"])
    ],
    targets: [
        .target(
            name: "FontCopyCore"
        ),
        .executableTarget(
            name: "FontCopy",
            dependencies: ["FontCopyCore"]
        ),
        .testTarget(
            name: "FontCopyTests",
            dependencies: ["FontCopyCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
