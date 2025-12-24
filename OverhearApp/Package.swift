// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Overhear",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMajor(from: "0.7.11")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "2.29.1"))
    ],
    targets: [
        .executableTarget(
            name: "Overhear",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm")
            ],
            path: ".",
            exclude: [
                "Overhear.xcodeproj",
                "DerivedData",
                "build",
                ".build",
                "Tests",
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OverhearTests",
            dependencies: ["Overhear"],
            path: "Tests/OverhearTests"
        )
    ]
)
