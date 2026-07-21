// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Parley",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Parley",
            path: "Sources/Parley",
            exclude: ["Info.plist"],
            resources: [.copy("Resources/ready"), .copy("Resources/lines")],
            linkerSettings: [
                // Embed an Info.plist into the bare SPM executable so it runs as a
                // menu-bar accessory (LSUIElement) and can request mic access.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Parley/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "ParleyTests",
            dependencies: ["Parley"],
            path: "Tests/ParleyTests"
        ),
    ]
)
