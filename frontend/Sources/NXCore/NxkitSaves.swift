import Foundation

/// The save of a Mac app nxkit built, under nxkit's names (nxkit `docs/nxkit-host.md`, Saves). The save is outside the app,
/// `~/Library/Application Support/nxkit/<TITLE ID>/save`, or the folder `NXKIT_SAVE` names. `NXKIT_USER` (1 to 8) picks the
/// game's user and `NXKIT_NICK` names user 1. The cloud saves (`NXKIT_SAVE_SYNC`, `NXKIT_SAVE_SYNC_CHOICE`) write the files of
/// the old engine, so both engines share a save. The launcher asks the app's own `nxkit-host` for the report before the start
/// and for the send after the game ended.
package struct NxkitSaveEngine: SaveEngine {
    package init() {}
    package var saveKey: String { "NXKIT_SAVE" }
    package var syncKey: String { "NXKIT_SAVE_SYNC" }
    package var choiceKey: String { "NXKIT_SAVE_SYNC_CHOICE" }
    /// Without a choice the newer save wins when both changed. `ask` keeps both and sends nothing, so a save that changes in the
    /// cloud after the report is not replaced without the player.
    package var unaskedChoice: String? { "ask" }
    package var psoUserKey: String? { nil }
    package var savesInLibraryFolder: Bool { false }

    package func defaultSave(titleID: String, support: URL) -> URL {
        support.appendingPathComponent("nxkit").appendingPathComponent(titleID.uppercased()).appendingPathComponent("save")
    }

    /// A player plays as the game's user 1 in their own save folder (PlayerProfile), under the player's name.
    package func playerEnvironment(name: String) -> [String: String] {
        var env = ["NXKIT_USER": "1"]
        if !name.isEmpty { env["NXKIT_NICK"] = name }
        return env
    }

    package func takesChoice(app: String) -> Bool { true }

    package func reportCommand(app: String, wait: TimeInterval) -> [String]? {
        [Self.host(app: app), "--save-sync-report=\(max(0, Int(wait * 1000)))"]
    }

    package func sendCommand(app: String) -> [String]? { [Self.host(app: app), "--save-sync-send"] }

    /// The app's program, which also answers the launcher's cloud save commands.
    package static func host(app: String) -> String {
        URL(fileURLWithPath: app).appendingPathComponent("Contents/MacOS").appendingPathComponent(NxkitBuilder.hostName).path
    }
}
