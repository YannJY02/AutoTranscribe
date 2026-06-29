// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InsightKitApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InsightKitApp", targets: ["InsightKitApp"]),
    ],
    targets: [
        .target(
            name: "InsightKitObjCShims",
            path: "Sources/InsightKitObjCShims",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "InsightKitApp",
            dependencies: ["InsightKitObjCShims"],
            path: "Sources/InsightKitApp"
        ),
        .testTarget(
            name: "InsightKitAppTests",
            dependencies: ["InsightKitApp", "InsightKitObjCShims"],
            path: "Tests/InsightKitAppTests"
        ),
    ]
)
