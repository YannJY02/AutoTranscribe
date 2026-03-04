// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InsightKitApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InsightKitApp", targets: ["InsightKitApp"]),
    ],
    targets: [
        .executableTarget(
            name: "InsightKitApp",
            path: "Sources/InsightKitApp"
        ),
        .testTarget(
            name: "InsightKitAppTests",
            dependencies: ["InsightKitApp"],
            path: "Tests/InsightKitAppTests"
        ),
    ]
)
