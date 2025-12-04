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
            exclude: ["Overhear.xcodeproj", "Resources/Info.plist"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
