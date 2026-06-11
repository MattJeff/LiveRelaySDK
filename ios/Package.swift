// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveRelaySDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "LiveRelaySDK",
            targets: ["LiveRelaySDK"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "120.0.0")
    ],
    targets: [
        .target(
            name: "LiveRelaySDK",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources/LiveRelaySDK"
        )
    ]
)
