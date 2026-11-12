// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PayloadKit",
    platforms: [.macOS(.v13), .iOS(.v26)],
    products: [
        .library(name: "PayloadKit", targets: ["PayloadKit"])
    ],
    targets: [
        .target(name: "PayloadValidation"),
        .target(name: "PayloadKit", dependencies: ["PayloadValidation"]),
        .testTarget(name: "PayloadKitTests", dependencies: ["PayloadKit"])
    ]
)
