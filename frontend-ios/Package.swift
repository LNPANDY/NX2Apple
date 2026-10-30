// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShellUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ShellUI", targets: ["ShellUI"]),
        // The controller adapter: GameController input turned into ShellInput, kept apart from the views.
        .library(name: "ShellControllers", targets: ["ShellControllers"]),
        // The host layer behind the views: catalogue, settings, game data, cloud saves, log and the launcher seam.
        .library(name: "ShellHost", targets: ["ShellHost"]),
        .executable(name: "ShellDemo", targets: ["ShellDemo"])
    ],
    targets: [
        .target(name: "ShellUI", resources: [.process("Resources")]),
        .target(name: "ShellControllers", dependencies: ["ShellUI"]),
        .target(name: "ShellHost", dependencies: ["ShellUI", "ShellControllers"], resources: [.process("Resources")]),
        .executableTarget(name: "ShellDemo", dependencies: ["ShellUI", "ShellControllers", "ShellHost"], resources: [.process("Resources")]),
        .testTarget(name: "ShellUITests", dependencies: ["ShellUI"]),
        .testTarget(name: "ShellHostTests", dependencies: ["ShellHost", "ShellUI", "ShellControllers"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ShellControllersTests", dependencies: ["ShellControllers", "ShellUI"])
    ]
)
