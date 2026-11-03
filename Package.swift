// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Okumalik",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Okumalik", path: "Sources/Okumalik")
    ]
)
