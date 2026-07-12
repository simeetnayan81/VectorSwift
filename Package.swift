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
        .executable(
            name: "VectorSwiftExample",
            targets: ["VectorSwiftExample"]
        ),
    ],
    targets: [
        .target(
            name: "VectorSwiftCore",
            path: "Sources/VectorSwiftCore"
        ),
        .target(
            name: "VectorSwiftStorage",
            dependencies: ["VectorSwiftCore"],
            path: "Sources/VectorSwiftStorage"
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
                "VectorSwiftStorage",
                "VectorSwiftCompute",
                "VectorSwiftIndex",
                "VectorSwiftQuery",
            ],
            path: "Sources/VectorSwift"
        ),
        .executableTarget(
            name: "VectorSwiftExample",
            dependencies: ["VectorSwift"],
            path: "Examples/QuickStart"
        ),
        .testTarget(
            name: "VectorSwiftTests",
            dependencies: [
                "VectorSwift",
                "VectorSwiftCompute",
                "VectorSwiftIndex",
                "VectorSwiftStorage",
            ],
            path: "Tests/VectorSwiftTests"
        ),
    ]
)
