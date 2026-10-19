// swift-tools-version:5.10
import PackageDescription

let dfLib = "dfcore/target/release"

let package = Package(
    name: "Quiet",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CRing"),
        .systemLibrary(name: "CDFCore"),
        .target(
            name: "QuietCore",
            dependencies: ["CRing", "CDFCore"],
            linkerSettings: [
                .unsafeFlags(["-L", dfLib]),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(name: "Quiet", dependencies: ["QuietCore"]),
        .executableTarget(name: "quiet-cli", dependencies: ["QuietCore"]),
    ]
)
