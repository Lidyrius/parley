// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vloude",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Vloude",
            path: "Sources/Vloude",
            exclude: ["Info.plist"],
            resources: [.copy("Resources/ready")],
            linkerSettings: [
                // Embed an Info.plist into the bare SPM executable so it runs as a
                // menu-bar accessory (LSUIElement) and can request mic access.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Vloude/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "VloudeTests",
            dependencies: ["Vloude"],
            path: "Tests/VloudeTests"
        ),
    ]
)
