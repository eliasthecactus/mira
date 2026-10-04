// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mira",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "Mira",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/Mira",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Network"),
                .linkedFramework("Foundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                // Embed Info.plist so the bare executable has a bundle ID and the
                // Local Network / Bonjour usage strings (macOS 15+ local network privacy).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", Context.packageDirectory + "/Support/Info.plist"]),
            ]
        ),
        .testTarget(
            name: "MiraTests",
            dependencies: ["Mira"],
            path: "Tests/MiraTests"
        )
    ]
)
