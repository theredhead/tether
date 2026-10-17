// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Tether", targets: ["Tether"])],
    targets: [
        .executableTarget(name: "Tether"),
        .testTarget(name: "TetherTests", dependencies: ["Tether"])
    ]
)
