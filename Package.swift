// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "codex-app-server",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CodexAppServer",
            targets: ["CodexAppServer"]
        ),
        .library(
            name: "CodexAppServerClient",
            targets: ["CodexAppServerClient"]
        ),
        .library(
            name: "CodexAppServerProtocol",
            targets: ["CodexAppServerProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "CodexAppServerProtocol"
        ),
        .target(
            name: "CodexAppServerClient",
            dependencies: ["CodexAppServerProtocol"]
        ),
        .target(
            name: "CodexAppServer",
            dependencies: ["CodexAppServerClient", "CodexAppServerProtocol"]
        ),
        .testTarget(
            name: "CodexAppServerTests",
            dependencies: ["CodexAppServer", "CodexAppServerClient"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
