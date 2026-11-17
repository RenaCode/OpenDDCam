// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenDDCamKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenDDCamKit", targets: ["OpenDDCamKit"])
    ],
    targets: [
        .target(
            name: "OpenDDCamKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenDDCamKitTests",
            dependencies: ["OpenDDCamKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
