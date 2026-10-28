// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NSPortBuilder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NSPortBuilder", path: "Sources/NSPortBuilder", resources: [.process("Resources")]),
        .testTarget(name: "NSPortBuilderTests", dependencies: ["NSPortBuilder"])
    ]
)
