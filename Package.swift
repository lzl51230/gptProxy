// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ChatGPTProxy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChatGPTProxyCore", targets: ["ChatGPTProxyCore"]),
        .executable(name: "ChatGPTProxyApp", targets: ["ChatGPTProxyApp"]),
        .executable(name: "DNSProtectionHelper", targets: ["DNSProtectionHelper"]),
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        .target(name: "CCodexTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "CDNSFirewall"),
        .target(
            name: "ChatGPTProxyCore",
            dependencies: ["CCodexTransport", .product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "ChatGPTProxyApp",
            dependencies: ["ChatGPTProxyCore"]
        ),
        .executableTarget(name: "DNSProtectionHelper", dependencies: ["ChatGPTProxyCore", "CDNSFirewall"]),
        .testTarget(
            name: "ChatGPTProxyCoreTests",
            dependencies: ["ChatGPTProxyCore"]
        ),
        .testTarget(
            name: "ChatGPTProxyAppTests",
            dependencies: ["ChatGPTProxyApp"]
        ),
        .testTarget(name: "DNSProtectionHelperTests", dependencies: ["DNSProtectionHelper", "ChatGPTProxyCore"]),
    ]
)
