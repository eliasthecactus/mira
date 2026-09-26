// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mira",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Mira",
            path: "Sources/Mira",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Network"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "MiraTests",
            dependencies: [],
            path: "Tests/MiraTests"
        )
    ]
)
