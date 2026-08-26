// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Richard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Richard", targets: ["Richard"])
    ],
    targets: [
        .executableTarget(
            name: "Richard",
            path: "Sources/Richard"
        )
    ]
)
