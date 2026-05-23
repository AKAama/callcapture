// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CallCapture",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CallCapture",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources"
        )
    ]
)
