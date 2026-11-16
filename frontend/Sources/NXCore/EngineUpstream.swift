import Foundation

package enum EngineUpstreamKind: String, Codable, CaseIterable, Equatable, Sendable {
    case nxnative
    case s2arm
    case macNativeGames = "macnativegames"
}

package struct EngineUpstreamDescriptor: Equatable, Sendable {
    package let kind: EngineUpstreamKind
    package let markerPaths: [String]
    package let requiredTools: [String]
    package let environmentPrefixes: [String]

    package init(kind: EngineUpstreamKind, markerPaths: [String], requiredTools: [String], environmentPrefixes: [String]) {
        self.kind = kind
        self.markerPaths = markerPaths
        self.requiredTools = requiredTools
        self.environmentPrefixes = environmentPrefixes
    }
}

package enum EngineUpstream {
    package static let descriptors: [EngineUpstreamDescriptor] = [
        EngineUpstreamDescriptor(
            kind: .nxnative,
            markerPaths: ["dm/tools/nx_extract/Program.cs"],
            requiredTools: [RepoLayout.buildScript, RepoLayout.romfsImageTool],
            environmentPrefixes: ["DM_"]
        ),
        EngineUpstreamDescriptor(
            kind: .s2arm,
            markerPaths: ["pack/jobs/main.py", "runtime/rewriter/rewriter.c"],
            requiredTools: ["pack/jobs/main.py"],
            environmentPrefixes: ["S2A_", "DM_"]
        ),
        EngineUpstreamDescriptor(
            kind: .macNativeGames,
            markerPaths: ["build_app.py", "games/totk"],
            requiredTools: ["build_app.py"],
            environmentPrefixes: ["MNG_", "TOTK_"]
        )
    ]

    package static func descriptor(for kind: EngineUpstreamKind) -> EngineUpstreamDescriptor {
        descriptors.first(where: { $0.kind == kind })!
    }

    package static func isTree(_ directory: String, kind: EngineUpstreamKind, fileManager fm: FileManager = .default) -> Bool {
        guard !directory.isEmpty else { return false }
        let desc = descriptor(for: kind)
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return desc.markerPaths.allSatisfy { fm.fileExists(atPath: prefix + $0) }
    }

    package static func detect(in directory: String, fileManager fm: FileManager = .default) -> EngineUpstreamKind? {
        guard !directory.isEmpty else { return nil }
        if EngineLayout.hasEngineTool(directory)
            || isTree(directory, kind: .nxnative, fileManager: fm)
            || isTree(directory + "/engine", kind: .nxnative, fileManager: fm) {
            return .nxnative
        }
        if isTree(directory, kind: .s2arm, fileManager: fm) {
            return .s2arm
        }
        if isTree(directory, kind: .macNativeGames, fileManager: fm) {
            return .macNativeGames
        }
        return nil
    }

    package static let macNativeGamesBundleTitleIDs: [String: String] = [
        "org.macnativegames.totk": "0100F2C0115B6000",
        "org.macnativegames.totk-native": "0100F2C0115B6000",
        "org.macnativegames.botw": "01007EF00011E000",
        "org.macnativegames.pokopia": "0400A3A01EE4C000",
        "org.macnativegames.pkp": "0400A3A01EE4C000",
        "org.macnativegames.bananza": "040074A01BF12000",
        "org.macnativegames.dkb": "040074A01BF12000",
        "org.macnativegames.oot": "0400486024DEC000",
        "org.macnativegames.oot-native": "0400486024DEC000",
        "org.macnativegames.dread": "010093801237C000",
        "org.macnativegames.ss": "01002DA013484000",
        "org.macnativegames.worldend": "010048900CF64000",
        "org.macnativegames.alc": "01007300020FA000",
        "org.macnativegames.aoc": "01002B00111A2000",
        "org.macnativegames.by3": "01004A4010FEA000",
        "org.macnativegames.jamboree": "0100965017338000",
        "org.macnativegames.la": "01006BB00C6F0000",
        "org.macnativegames.mk8d": "0100152000022000",
        "org.macnativegames.mkw": "0400C3F00006E000",
        "org.macnativegames.mvdk": "0100B99019412000",
        "org.macnativegames.ori": "010061D00DB74000",
        "org.macnativegames.ssbu": "01006A800016E000",
        "org.macnativegames.tomodachi": "010051F0207B2000",
        "org.macnativegames.unicorn": "010054B01AD92000",
        "org.macnativegames.wonder": "010015100B514000"
    ]
}
