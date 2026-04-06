// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImHear",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ImHear",
            path: "ImHear",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("SoundAnalysis"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
            ]
        )
    ]
)
