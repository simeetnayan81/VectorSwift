// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VectorSwift",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "VectorSwift",
            targets: ["VectorSwift"]
        ),
    ],
    targets: [
        .target(
            name: "VectorSwiftCore",
            path: "Sources/VectorSwiftCore"
        ),
        .target(
            name: "VectorSwiftCompute",
            dependencies: ["VectorSwiftCore"],
            path: "Sources/VectorSwiftCompute"
        ),
        .target(
            name: "VectorSwiftIndex",
            dependencies: ["VectorSwiftCompute", "VectorSwiftCore"],
            path: "Sources/VectorSwiftIndex"
        ),
        .target(
            name: "VectorSwiftQuery",
            dependencies: ["VectorSwiftIndex", "VectorSwiftCompute", "VectorSwiftCore"],
            path: "Sources/VectorSwiftQuery"
        ),
        .target(
            name: "VectorSwift",
            dependencies: [
                "VectorSwiftCore",
                "VectorSwiftCompute",
                "VectorSwiftIndex",
                "VectorSwiftQuery",
            ],
            path: "Sources/VectorSwift"
        ),
        .testTarget(
            name: "VectorSwiftTests",
            dependencies: [
                "VectorSwift",
                "VectorSwiftCompute",
                "VectorSwiftIndex",
            ],
            path: "Tests/VectorSwiftTests"
        ),
    ]
)
