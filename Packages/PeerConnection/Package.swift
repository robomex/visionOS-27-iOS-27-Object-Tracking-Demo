// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PeerConnection",
    platforms: [
        .iOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "PeerConnection",
                 targets: ["PeerConnection"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", .upToNextMajor(from: "1.0.0"))
    ],
    targets: [
        .target(name: "PeerConnection",
                dependencies: [.product(name: "X509", package: "swift-certificates")])
    ]
)
