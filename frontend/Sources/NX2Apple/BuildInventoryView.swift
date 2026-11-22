import Foundation
import NXCore
import NXModel

/// One current record per title. Artifact presence never implies a live mobile installation.
struct BuildInventoryEntry: Identifiable {
    let game: LibraryGame
    let mac: Bool
    let mobile: Mobile
    let installed: Bool
    /// Read once here: the Mac package's version reads the bundle.
    let version: String?
    /// The name shown for its language (`named(_:)`).
    private(set) var displayName = ""
    enum Mobile { case none, app, ipa }
    var id: UUID { game.id }
    init(_ game: LibraryGame) {
        self.game = game
        let app = game.playableMacBundle   // one read for `isReady` and `playVersion`
        mac = app != nil
        installed = game.onDevice
        mobile = game.hasIOSApp ? .app : (game.hasIPA ? .ipa : .none)
        version = app?.version ?? (mac ? nil : game.unbuiltVersion)
    }
    func named(_ lang: Lang) -> Self {
        var entry = self
        entry.displayName = game.displayName(lang)
        return entry
    }
}
