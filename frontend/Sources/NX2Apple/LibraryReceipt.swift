import AppKit
import Foundation
import NXCore
import UniformTypeIdentifiers

/// File paths for completed builds on this Mac. No source packages, keys or device state travel with the receipt.
struct LibraryReceipt: Encodable {
    struct Game: Encodable {
        let id: String
        let name: String
        let version: String
        let macAppPath: String?
        let archivePath: String?
        let frameworkPath: String?

        init?(game: LibraryGame, files: FileManager) {
            let title = game.titleID.uppercased()
            guard title.count == 16, title.allSatisfy({ $0.isHexDigit }) else { return nil }
            let playable = game.playableMacBundle
            let framework = URL(fileURLWithPath: game.iosAppPath)
                .appendingPathComponent("Frameworks/DmGame\(title).framework").path
            let hasPhoneBuild = game.hasIOSApp && !game.archivePath.isEmpty
                && files.fileExists(atPath: game.archivePath + "/romfs.img")
                && files.fileExists(atPath: framework + "/game.manifest.json")
            guard playable != nil || hasPhoneBuild else { return nil }
            id = title
            name = game.displayName(Lang.initial())
            version = playable?.version ?? game.sourceVersion
            macAppPath = playable == nil ? nil : game.appPath
            archivePath = hasPhoneBuild ? game.archivePath : nil
            frameworkPath = hasPhoneBuild ? framework : nil
        }
    }

    let schema = 1
    let games: [Game]

    init(games: [LibraryGame], files: FileManager = .default) {
        self.games = games.compactMap { Game(game: $0, files: files) }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    @MainActor static func share(_ games: [LibraryGame], lang: Lang) {
        let receipt = LibraryReceipt(games: games)
        guard !receipt.games.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.string("library.receiptEmpty", lang)
            alert.runModal()
            return
        }
        let workspace = NSWorkspace.shared
        if let companion = workspace.urlForApplication(withBundleIdentifier: "me.jaack.nx2-game-library") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("nx2library")
            do {
                try receipt.write(to: url)
                workspace.open([url], withApplicationAt: companion, configuration: .init()) { _, error in
                    guard let error else { return }
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
                return
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nx2library") ?? .json]
        panel.nameFieldStringValue = "NX2 Library.nx2library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try receipt.write(to: url) }
        catch { NSAlert(error: error).runModal() }
    }
}
