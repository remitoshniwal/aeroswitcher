// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AeroSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AeroSwitcher",
            path: "Sources/AeroSwitcher"
        )
    ]
)
