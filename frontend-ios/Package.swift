// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShellUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ShellUI", targets: ["ShellUI"]),
        // The controller adapter: GameController input turned into ShellInput, kept apart from the views.
        .library(name: "ShellControllers", targets: ["ShellControllers"]),
        .executable(name: "ShellDemo", targets: ["ShellDemo"])
    ],
    targets: [
        .target(name: "ShellUI", resources: [.process("Resources")]),
        .target(name: "ShellControllers", dependencies: ["ShellUI"]),
        .executableTarget(name: "ShellDemo", dependencies: ["ShellUI", "ShellControllers"], resources: [.process("Resources")]),
        .testTarget(name: "ShellUITests", dependencies: ["ShellUI"]),
        .testTarget(name: "ShellControllersTests", dependencies: ["ShellControllers", "ShellUI"])
    ]
)
