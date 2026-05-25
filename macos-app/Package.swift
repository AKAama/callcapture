// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CallCapture",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.14.7"))
    ],
    targets: [
        .executableTarget(
            name: "CallCapture",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "CallCaptureTests",
            dependencies: ["CallCapture"],
            path: "Tests/CallCaptureTests"
        )
    ]
)
