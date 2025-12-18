// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Overhear",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMajor(from: "0.7.11"))
    ],
    targets: [
        .executableTarget(
            name: "Overhear",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: ".",
            exclude: ["Overhear.xcodeproj", "Resources/Info.plist", "Tests"],
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
