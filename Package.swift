// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ChatGPTProxy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChatGPTProxyCore", targets: ["ChatGPTProxyCore"]),
        .executable(name: "ChatGPTProxyApp", targets: ["ChatGPTProxyApp"]),
    ],
    targets: [
        .target(
            name: "ChatGPTProxyCore"
        ),
        .executableTarget(
            name: "ChatGPTProxyApp",
            dependencies: ["ChatGPTProxyCore"]
        ),
        .testTarget(
            name: "ChatGPTProxyCoreTests",
            dependencies: ["ChatGPTProxyCore"]
        ),
        .testTarget(
            name: "ChatGPTProxyAppTests",
            dependencies: ["ChatGPTProxyApp"]
        ),
    ]
)
