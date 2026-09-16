// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioSplit",
    platforms: [
        // Process taps require macOS 14.2; AudioSplit requires 14.4 for the
        // aggregate-device-with-tap behaviour it relies on.
        .macOS("14.4")
    ],
    products: [
        .library(name: "AudioSplitEngine", targets: ["AudioSplitEngine"]),
        .executable(name: "AudioSplitApp", targets: ["AudioSplitApp"]),
        .executable(name: "audiosplit-probe", targets: ["audiosplit-probe"]),
        .executable(name: "audiosplit-m2", targets: ["audiosplit-m2"]),
        .executable(name: "audiosplit-m3", targets: ["audiosplit-m3"]),
    ],
    targets: [
        .target(name: "CAudioSplitAtomics"),
        .target(
            name: "AudioSplitEngine",
            dependencies: ["CAudioSplitAtomics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "audiosplit-probe",
            dependencies: ["AudioSplitEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AudioSplitApp",
            dependencies: ["AudioSplitEngine"],
            // Copied into the bundle by Scripts/make-app.sh, not compiled.
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AudioSplitEngineTests",
            dependencies: ["AudioSplitEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "audiosplit-m3",
            dependencies: ["AudioSplitEngine"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/audiosplit-m3/Info.plist",
            ])]
        ),
        .executableTarget(
            name: "audiosplit-m2",
            dependencies: ["AudioSplitEngine"],
            // Consumed by the linker via -sectcreate, not by SwiftPM.
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // A process tap yields silence unless TCC has granted audio capture,
            // and TCC will not consider a binary with no bundle identity and no
            // usage description. Embedding the Info.plist in __TEXT gives this
            // command-line tool both without making it an .app.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/audiosplit-m2/Info.plist",
            ])]
        ),
    ]
)
