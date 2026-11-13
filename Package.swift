// swift-tools-version: 6.1

import PackageDescription

import Foundation
let rustTarget = ProcessInfo.processInfo.environment["GPTPROXY_RUST_TARGET"] ?? {
    #if arch(arm64)
    return "aarch64-apple-darwin"
    #else
    return "x86_64-apple-darwin"
    #endif
}()
let rustLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("build/rust/\(rustTarget)/release").path

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
        .target(name: "CRustProxy", linkerSettings: [.unsafeFlags([rustLibrary + "/libgpt_proxy_core.a"]), .linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .target(name: "CDNSFirewall"),
        .target(
            name: "ChatGPTProxyCore",
            dependencies: ["CRustProxy"]
        ),
        .executableTarget(
            name: "ChatGPTProxyApp",
            dependencies: ["ChatGPTProxyCore"]
        ),
        .executableTarget(name: "AppUpdater", dependencies: ["ChatGPTProxyCore"]),
        .executableTarget(name: "DNSProtectionHelper", dependencies: ["ChatGPTProxyCore", "CDNSFirewall"]),
        .testTarget(
            name: "ChatGPTProxyCoreTests",
            dependencies: ["ChatGPTProxyCore", .product(name: "Yams", package: "Yams")]
        ),
        .testTarget(
            name: "ChatGPTProxyAppTests",
            dependencies: ["ChatGPTProxyApp"]
        ),
        .testTarget(name: "DNSProtectionHelperTests", dependencies: ["DNSProtectionHelper", "ChatGPTProxyCore"]),
    ]
)
