import SwiftUI
import ShellHost
import ShellUI

/// `--host`: the same views on `ShellHost` instead of the sample values. The games are the fixture bundles from
/// `Tests/ShellHostTests/Fixtures/Games` (in the app's `Games` folder, or `--games-dir <folder>`): valid ones, one built
/// for another chain, one for a newer OS, and broken ones. Each valid game gets an empty marker file in a temporary
/// app-data folder, which makes it playable, except "Quiet Fixture", which stays at "needs game data". Launching is the
/// stub. Choices go to throwaway defaults suites that are cleared at every start.
struct HostDemoScreen: View {
    @State private var model: ShellHostModel

    init() {
        let args = ProcessInfo.processInfo.arguments
        let fm = FileManager.default
        let gamesRoot: URL
        if let i = args.firstIndex(of: "--games-dir"), args.indices.contains(i + 1) {
            gamesRoot = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else {
            gamesRoot = Bundle.main.url(forResource: "Games", withExtension: nil)
                ?? (fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory).appendingPathComponent("Games")
        }
        let appData = fm.temporaryDirectory.appendingPathComponent("shell-demo-appdata", isDirectory: true)
        try? fm.removeItem(at: appData)
        try? fm.createDirectory(at: appData, withIntermediateDirectories: true)
        let entries = GameCatalogue.scan(root: gamesRoot)
        for entry in entries { UserDefaults().removePersistentDomain(forName: Self.suite + entry.id) }
        let omitMSL: String? = args.firstIndex(of: "--omit-msl")
            .flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        for entry in entries where entry.problem == nil && entry.id != "0100000000080000" {
            guard let marker = entry.manifest?.romfsMarker else { continue }
            let gameDir = appData.appendingPathComponent(entry.id, isDirectory: true)
            let file = gameDir.appendingPathComponent("romfs", isDirectory: true).appendingPathComponent(marker)
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: Data())
            if entry.id != omitMSL {
                let rawChain = entry.manifest?.chain ?? ""
                let chain = rawChain.isEmpty ? "b-3f9a2c" : rawChain
                let mslFile = gameDir.appendingPathComponent("msl", isDirectory: true)
                    .appendingPathComponent(chain, isDirectory: true)
                    .appendingPathComponent("fixture.metallib")
                try? fm.createDirectory(at: mslFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("fixture".utf8).write(to: mslFile)
            }
        }
        let suite = Self.suite
        let config = ShellHostConfig(gamesRoot: gamesRoot, appDataRoot: appData,
                                     environment: HostEnvironment(chain: "b-3f9a2c"),
                                     updateURL: URL(string: "https://github.com/LNPANDY/NX2Apple/releases"),
                                     defaults: { UserDefaults(suiteName: suite + $0) ?? .standard })
        #if canImport(UIKit)
        _model = State(initialValue: ShellHostModel(config: config, picker: DocumentFolderPicker()))
        #else
        _model = State(initialValue: ShellHostModel(config: config))
        #endif
    }

    private static let suite = "dev.nx2apple.shell.demo."

    var body: some View {
        ShellHostView(model: model, initialSelection: ProcessInfo.processInfo.arguments.firstIndex(of: "--select")
            .flatMap { ProcessInfo.processInfo.arguments.indices.contains($0 + 1) ? ProcessInfo.processInfo.arguments[$0 + 1] : nil },
                       initialDetailOpen: ProcessInfo.processInfo.arguments.firstIndex(of: "--screen")
            .flatMap { ProcessInfo.processInfo.arguments.indices.contains($0 + 1) ? ProcessInfo.processInfo.arguments[$0 + 1] : nil } == "settings")
            .background(ShellPalette.background)
    }
}
