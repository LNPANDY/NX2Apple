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
        } else if args.contains("--mock-cheat-file") || args.contains("--mock-cheat-mismatch") || args.contains("--mock-cheat-preloaded") || args.contains("--mock-cheat-fuse") {
            let bundled = Bundle.main.url(forResource: "Games", withExtension: nil)
                ?? (fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory).appendingPathComponent("Games")
            let scratchGames = fm.temporaryDirectory.appendingPathComponent("shell-demo-games-cheats", isDirectory: true)
            try? fm.removeItem(at: scratchGames)
            try? fm.copyItem(at: bundled, to: scratchGames)
            let dmDir = scratchGames
                .appendingPathComponent("0100000000010000", isDirectory: true)
                .appendingPathComponent("DmGame.framework", isDirectory: true)
                .appendingPathComponent("dm", isDirectory: true)
            try? fm.createDirectory(at: dmDir, withIntermediateDirectories: true)
            let fixups = "# BUILD_ID\tCD57B23FA4BBAD65803D9788C01821EE\n# MAIN_RX_END\t0x100000\n"
            try? Data(fixups.utf8).write(to: dmDir.appendingPathComponent("main.fixups.tsv"))
            let trampolines = """
            # BUILD_ID\tCD57B23FA4BBAD65
            # MAIN_RX_END\t0x100000
            # SLOTS_USED\t1
            row_type\tname\tcheat_key\tkind\tslot_id\tvariant_mask\ttarget_off\tpatched_word\tkey_mask\tdetail
            entry\tMoon Jump (Hold ZR+B)\tMoon Jump (Hold ZR+B)\tbaked_conditional\t0\t0x1\t0x400\t0xd503201f\t0x202\t
            site\tMoon Jump (Hold ZR+B)\tMoon Jump (Hold ZR+B)\tbaked_conditional\t0\t0x1\t0x400\t0xd503201f\t0x202\t
            """
            try? Data(trampolines.utf8).write(to: dmDir.appendingPathComponent("cheat_trampolines.tsv"))
            gamesRoot = scratchGames
        } else {
            gamesRoot = Bundle.main.url(forResource: "Games", withExtension: nil)
                ?? (fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory).appendingPathComponent("Games")
        }
        let appData = fm.temporaryDirectory.appendingPathComponent("shell-demo-appdata", isDirectory: true)
        try? fm.removeItem(at: appData)
        try? fm.createDirectory(at: appData, withIntermediateDirectories: true)
        let sampleCheatText = """
        [Player Stats]
        20000000
        [Infinite Health]
        04000000 00180020 000003E7
        [Max Rupees]
        04100000 00004200 000F423F
        [Player Stats End]
        20000001
        [--SectionStart:Movement & Combat--]
        [Moon Jump (Hold ZR+B)]
        80000202
        04000000 00000400 D503201F
        20000000
        [2x Movement Speed]
        04000000 00000800 1E202800
        [Instant Charge (Hold L)]
        80000040
        04000000 00000C00 D503201F
        20000000
        [--SectionEnd:Movement & Combat--]
        """
        if args.contains("--mock-cheat-preloaded") || args.contains("--mock-cheat-fuse") {
            let cheatsDir = appData
                .appendingPathComponent("0100000000010000", isDirectory: true)
                .appendingPathComponent("cheats", isDirectory: true)
            try? fm.createDirectory(at: cheatsDir, withIntermediateDirectories: true)
            try? Data(sampleCheatText.utf8).write(to: cheatsDir.appendingPathComponent("CD57B23FA4BBAD65.txt"))
            try? Data("Infinite Health\nMoon Jump (Hold ZR+B)\n".utf8).write(to: cheatsDir.appendingPathComponent("CD57B23FA4BBAD65.enabled"))
            if args.contains("--mock-cheat-fuse") {
                let fuse = CheatFuseGuard(titleID: "0100000000010000", folder: cheatsDir)
                _ = fuse.armBeforeLaunch(buildID: "CD57B23FA4BBAD65")
                _ = fuse.recoverIfArmed()
            }
        }
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
                                     defaults: { UserDefaults(suiteName: suite + $0) ?? .standard },
                                     sideloadCertBacking: InMemoryCertBacking())
        let folderPicker: any FolderPicker
        if args.contains("--mock-bad-folder") {
            let emptyFolder = fm.temporaryDirectory.appendingPathComponent("shell-demo-empty-folder", isDirectory: true)
            try? fm.removeItem(at: emptyFolder)
            try? fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
            folderPicker = DemoFixedFolderPicker(url: emptyFolder)
        } else {
            #if canImport(UIKit)
            folderPicker = DocumentFolderPicker()
            #else
            folderPicker = NoFolderPicker()
            #endif
        }
        let certPicker: any SideloadCertificatePicker
        if args.contains("--mock-cert-picker") {
            certPicker = DemoFixedCertificatePicker(data: Data("not-a-valid-pkcs12".utf8), fileName: "demo.p12")
        } else {
            #if canImport(UIKit)
            certPicker = DocumentCertificatePicker()
            #else
            certPicker = NoSideloadCertificatePicker()
            #endif
        }
        let cheatPicker: any CheatFilePicker
        if args.contains("--mock-cheat-file") {
            cheatPicker = DemoFixedCheatFilePicker(data: Data(sampleCheatText.utf8), fileName: "CD57B23FA4BBAD65.txt")
        } else if args.contains("--mock-cheat-mismatch") {
            cheatPicker = DemoFixedCheatFilePicker(data: Data(sampleCheatText.utf8), fileName: "AABBCCDDEEFF0011.txt")
        } else {
            #if canImport(UIKit)
            cheatPicker = DocumentCheatFilePicker()
            #else
            cheatPicker = NoCheatFilePicker()
            #endif
        }
        _model = State(initialValue: ShellHostModel(config: config, picker: folderPicker, certificatePicker: certPicker, cheatPicker: cheatPicker))
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

private struct DemoFixedFolderPicker: FolderPicker {
    let url: URL
    func pickFolder() async -> URL? { url }
}

private struct DemoFixedCertificatePicker: SideloadCertificatePicker {
    let data: Data
    let fileName: String
    func pickCertificateOutcome() async -> CertificatePickOutcome { .picked(data: data, fileName: fileName) }
}

private struct DemoFixedCheatFilePicker: CheatFilePicker {
    let data: Data
    let fileName: String
    func pickCheatFileOutcome() async -> CheatFilePickOutcome { .picked(data: data, fileName: fileName) }
}
