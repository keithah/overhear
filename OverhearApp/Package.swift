// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Overhear",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Overhear",
            dependencies: [],
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
