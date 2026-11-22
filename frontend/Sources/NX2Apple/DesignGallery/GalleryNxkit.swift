import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

/// The gallery's scenes of nxkit (Beta), LNPANDY/NX2Apple#1460: the engine row with nxkit chosen, nxkit on a Mac that cannot run it, a newer
/// release that is not signed, a build running, finished with "Did it work?", failed with nxb's exit code, and the library hero of a game
/// nxkit built. The pair is a stand-in in the fixtures' folder: nothing runs, nothing is downloaded.
extension GalleryFixtures {
    static let nxkitFailureLines = [
        "[2/5] RomFS: 1834 of 1834 files",
        "[3/5] shaders: translating 412 programs",
        "[RED] shader 0x3f2a: unsupported instruction IADD3.X",
        "nxb: stage shaders failed after 41.2 s",
    ]

    /// Every scene's build store gets a stand-in of the bundled pair (nxb, nxkit-host, MANIFEST.json), so nxkit (Beta) is in the engine pop-up.
    func configureNxkit(_ build: BuildStore) {
        let pair = directory.appendingPathComponent("nxbuild", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: pair.appendingPathComponent("MANIFEST.json").path) {
            try? fm.createDirectory(at: pair, withIntermediateDirectories: true)
            for name in ["nxb", "nxkit-host"] {
                fm.createFile(atPath: pair.appendingPathComponent(name).path, contents: Data("#!/bin/sh\nexit 1\n".utf8), attributes: [.posixPermissions: 0o755])
            }
            try? Data(#"{"format":1,"version":"0.10.3","platform":"macos","arch":"arm64","macos_min":"26.0","files":{"nxb":"ba20f1b45d8a","nxkit-host":"e01c6312144767845a60021bc69fb597dd0c6f4eec353ae6739e9e586e5e374b"}}"#.utf8)
                .write(to: pair.appendingPathComponent("MANIFEST.json"))
        }
        build.nxkitBundledFolder = pair.path
        build.nxkitVersions = NxkitVersionStore(root: directory.appendingPathComponent("nxkit-versions", isDirectory: true))
        build.nxkitAvailability = .available
        build.nxkitAutoUpdate = { false }
        build.refreshNxkit()
    }

    func nxkitView(_ scene: GalleryScene, stores: LauncherStores, library: GameLibrary,
                   launcher: (LauncherPage, Int, SettingsCategory) -> AnyView) -> AnyView {
        let build = stores.build
        let game = catalog[0]
        func prompt(_ moment: NxkitFeedbackPrompt.Moment, exit: Int32?) -> NxkitFeedbackPrompt {
            NxkitFeedbackPrompt(buildID: "gallery", moment: moment, titleID: game.titleID, gameName: game.name, gameVersion: "1.0.0",
                                nxkitVersion: "0.10.3", engineBuild: "e01c6312144767845a60021bc69fb597dd0c6f4eec353ae6739e9e586e5e374b",
                                exitCode: exit, log: Self.nxkitFailureLines.joined(separator: "\n"))
        }
        switch scene {
        case .nxkitEngine, .nxkitUnsigned:
            build.selectUpstream(.nxkit)
            if scene == .nxkitUnsigned { build.setNxkitUpdateForGallery(.rejected("0.11.0", .unsigned)) }
            else { build.setNxkitUpdateForGallery(.upToDate) }
            return launcher(.settings, 0, .tools)
        case .nxkitUnavailable:
            build.nxkitAvailability = .needsNewerMacOS
            build.refreshNxkit()
            return launcher(.settings, 0, .tools)
        case .nxkitRunning:
            configureBuild(stores, library: library)
            build.selectUpstream(.nxkit)
            build.buildingGame = true
            build.running = true
            build.overallProgress = 0.55
            build.stages = [Stage(id: 1, name: "Extract", state: .done), Stage(id: 2, name: "RomFS", state: .done),
                            Stage(id: 3, name: "Shaders", state: .running, detail: "231 / 412", percent: 56, started: Date().addingTimeInterval(-61), eta: 48, etaAt: Date()),
                            Stage(id: 4, name: "App", state: .pending)]
            build.say(String(format: build.t("nxkit.logHeaderBundled"), "0.10.3", "e01c63121447"))
            return launcher(.builds, 0, .general)
        case .nxkitFinished:
            configureBuild(stores, library: library)
            build.selectUpstream(.nxkit)
            let app = makeNxkitApp(for: 0, in: library)
            build.runningTarget = BuildTarget.mac
            build.macAppPath = library.games.first { $0.id == app }?.appPath ?? directory.appendingPathComponent("Game.app").path
            build.stages = [Stage(id: 1, name: "Shaders", state: .done), Stage(id: 2, name: "App", state: .done)]
            build.done = true
            build.nxkitFeedback = prompt(.built, exit: 0)
            return launcher(.builds, 1, .general)
        case .nxkitFailed:
            configureBuild(stores, library: library)
            build.selectUpstream(.nxkit)
            build.failure = BuildFailure(kind: .nxkit, gameName: nil, detail: "1", lines: Self.nxkitFailureLines)
            build.stages = [Stage(id: 1, name: "Extract", state: .done), Stage(id: 2, name: "Shaders", state: .failed, detail: "exit code 1")]
            build.nxkitFeedback = prompt(.failed, exit: 1)
            return launcher(.builds, 1, .general)
        case .nxkitGeneric:   // the hero of a game nxkit built without a game profile (v0lumehi/nxkit#54), already answered
            let id = makeNxkitApp(for: 0, in: library)
            if let app = library.games.first(where: { $0.id == id })?.appPath {
                try? Data(#"{"schema":1,"settings":[],"build":{"profile":"generic","engine":"unreal","graphics":"vulkan","evidence":["UnrealEngine"]}}"#.utf8)
                    .write(to: NxkitBuildProfile.listURL(app: app))
            }
            var records = build.nxkitRecords
            let buildID = "gallery-" + UUID().uuidString
            records[game.titleID.uppercased()] = NxkitBuildRecord(version: "0.10.3", hostBuild: "e01c6312144767845a60021bc69fb597",
                                                                  buildID: buildID, date: Date(timeIntervalSince1970: 1_789_000_000))
            build.nxkitRecords = records
            build.markNxkitFeedbackAsked(buildID + "." + NxkitFeedbackPrompt.Moment.firstLaunch.rawValue)
            return launcher(.library, 0, .general)
        default:   // .nxkitLibrary: the hero of a game nxkit built, after its first start
            _ = makeNxkitApp(for: 0, in: library)
            var records = build.nxkitRecords
            records[game.titleID.uppercased()] = NxkitBuildRecord(version: "0.10.3", hostBuild: "e01c6312144767845a60021bc69fb597",
                                                                  buildID: "gallery-" + UUID().uuidString, date: Date(timeIntervalSince1970: 1_789_000_000))
            build.nxkitRecords = records
            return launcher(.library, 0, .general)
        }
    }

    /// A stand-in of an app nxb built (bundle id `org.nxkit.game.<id>`, program `nxkit-host`, `Contents/Resources/nxkit`), pointing at /usr/bin/true.
    private func makeNxkitApp(for index: Int, in library: GameLibrary) -> UUID? {
        let game = catalog[index]
        let app = directory.appendingPathComponent("nxkit-apps-" + UUID().uuidString + "/\(game.name).app")
        let fm = FileManager.default
        try? fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: app.appendingPathComponent("Contents/Resources/nxkit"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/nxkit-host"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let info: [String: Any] = ["CFBundleDisplayName": game.name, "CFBundleName": game.name, "CFBundleExecutable": "nxkit-host",
                                   "CFBundleShortVersionString": "1.0.0", "CFBundleIdentifier": "org.nxkit.game." + game.titleID.lowercased()]
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        guard var entry = library.games.first(where: { $0.titleID == game.titleID }) else { return nil }
        entry.appPath = app.path
        entry.lastTarget = BuildTarget.mac
        library.upsert(entry)
        return entry.id
    }
}
