// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NSPortBuilder",
    platforms: [.macOS("26.6")],
    targets: [
        .executableTarget(name: "NSPortBuilder", path: "Sources/NSPortBuilder"),
        .testTarget(name: "NSPortBuilderTests", dependencies: ["NSPortBuilder"])
    ]
)
