import AppKit
import GameController
import os
import NXCore

/// The system's Home button setting for apps (#336): opening its screen in System Settings, and what a game's last session found
/// (HomeButtonHint reads the game's log). GameControllerHomeButtonSettingsManager is macOS 27 only, and opens the screen only while a
/// controller is connected: otherwise System Settings opens at its start and the player finds Game Controllers there.
enum HomeButtonSettings {
    private static let log = Logger(subsystem: "NX2Apple", category: "console.home")

    static var available: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }

    @MainActor static func open() {
        if #available(macOS 27.0, *) {
            do { try GCControllerHomeButtonSettingsManager().openControllerHomeButtonSettings(for: .customizeInAppAction); return }
            catch { log.notice("Home button settings did not open: \(error.localizedDescription, privacy: .public)") }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// The setting the game wrote to its log in its last session, nil when it wrote none. The game writes it when the first controller
    /// is there: at its start (the first megabyte of the log) or when one connects later (the end of the log). A log of hundreds of
    /// megabytes is not read whole.
    static func reported(by game: LibraryGame) -> String? {
        guard let url = GameLog.latest(titleID: game.titleID, appPath: game.appPath) else { return nil }
        if let lines = GameLog.tail(url, lines: 100_000), let found = HomeButtonHint.setting(fromLog: lines.joined(separator: "\n")) { return found }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1 << 20)).flatMap { HomeButtonHint.setting(fromLog: String(decoding: $0, as: UTF8.self)) }
    }
}
