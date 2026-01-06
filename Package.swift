// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnonCam",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "anoncam", targets: ["AnonCam"])
    ],
    targets: [
        .executableTarget(
            name: "AnonCam",
            path: "AnonCamApp/Sources",
            exclude: ["Metal/Shaders.metal"],  // Metal files will be added as resources
            sources: [
                "Camera",
                "Metal",  // This picks up .swift files but not .metal
                "UI"
            ],
            resources: [
                .process("Metal/Shaders.metal")  // Metal shader as resource
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Cocoa"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("IOSurface")
            ]
        )
    ]
)
