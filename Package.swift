// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ChatGPTProxy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChatGPTProxyCore", targets: ["ChatGPTProxyCore"]),
        .executable(name: "ChatGPTProxyApp", targets: ["ChatGPTProxyApp"]),
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        .target(
            name: "ChatGPTProxyCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
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
