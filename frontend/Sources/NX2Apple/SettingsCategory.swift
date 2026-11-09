import SwiftUI

/// The four parts of the Settings page (#678), in the order the selector shows them. One is visible at a time, each keeps its own
/// scroll position (ScrollMemory), and General is where it opens.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, library, controls, tools
    var id: String { rawValue }
    var labelKey: String { "settings.cat." + rawValue }
}

/// Cards that other parts of the launcher own and Settings only places, each in its fixed position. A slot that is nil draws nothing.
/// The launcher fills them in where it builds the page, so this file does not know those cards.
/// - `savedKeys`: Tools, the first card (operations' saved keys).
/// - `globalSaves`: Library, after Games folders (the shell stream's GlobalSavesCard, the one cloud saves setting).
/// - `players`: Library, after the global saves (PlayersCard).
/// - `stickDeadzones`: Controls, after the mapping and controller actions (StickDeadzoneCard).
/// - `gameSaves`: the Saves part of a game's options sheet, first (GameSavesSection of that game).
struct SettingsSlots {
    var savedKeys: AnyView?
    var globalSaves: AnyView?
    var players: AnyView?
    var stickDeadzones: AnyView?
    var gameSaves: ((LibraryGame) -> AnyView)?
}

private struct SettingsSlotsKey: EnvironmentKey { static let defaultValue = SettingsSlots() }

extension EnvironmentValues {
    var settingsSlots: SettingsSlots {
        get { self[SettingsSlotsKey.self] }
        set { self[SettingsSlotsKey.self] = newValue }
    }
}
