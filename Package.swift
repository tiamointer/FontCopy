// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FontPreviewerMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FontPreviewerMac", targets: ["FontPreviewerMac"]),
        .library(name: "FontPreviewerCore", targets: ["FontPreviewerCore"])
    ],
    targets: [
        .target(
            name: "FontPreviewerCore"
        ),
        .executableTarget(
            name: "FontPreviewerMac",
            dependencies: ["FontPreviewerCore"]
        ),
        .testTarget(
            name: "FontPreviewerMacTests",
            dependencies: ["FontPreviewerCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
