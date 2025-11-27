// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioSpike",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AudioSpike", targets: ["AudioSpike"])
    ],
    targets: [
        .executableTarget(
            name: "AudioSpike",
            exclude: ["Support/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AudioSpike/Support/Info.plist"
                ])
            ]
        )
    ]
)
