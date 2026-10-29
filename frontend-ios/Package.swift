// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShellUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ShellUI", targets: ["ShellUI"]),
        .executable(name: "ShellDemo", targets: ["ShellDemo"])
    ],
    targets: [
        .target(name: "ShellUI", resources: [.process("Resources")]),
        .executableTarget(name: "ShellDemo", dependencies: ["ShellUI"], resources: [.process("Resources")]),
        .testTarget(name: "ShellUITests", dependencies: ["ShellUI"])
    ]
)
