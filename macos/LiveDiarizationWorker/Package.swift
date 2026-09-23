// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveDiarizationWorker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InsightKitLiveDiarization", targets: ["LiveDiarizationWorker"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "3ebb2859709255e3c2703e170d9a36812f7b640a"
        ),
    ],
    targets: [
        .target(name: "LiveDiarizationCore"),
        .executableTarget(
            name: "LiveDiarizationWorker",
            dependencies: [
                "LiveDiarizationCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "LiveDiarizationCoreTests", dependencies: ["LiveDiarizationCore"]),
        .testTarget(
            name: "LiveDiarizationWorkerTests",
            dependencies: [
                "LiveDiarizationWorker",
                "LiveDiarizationCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
