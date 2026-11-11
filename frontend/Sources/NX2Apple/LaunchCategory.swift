import Foundation
import NXCore

/// The four parts of a game's options sheet (#675): Game, Performance, Mods and cheats, Saves. Where a setting of the game's
/// launcher.json goes is decided here from its variable (and, for one this table does not know, from its section), so a new
/// setting lands somewhere sensible without a change.
enum LaunchCategory: String, CaseIterable, Identifiable {
    case game, performance, mods, saves
    var id: String { rawValue }
    var labelKey: String { "launch.cat." + rawValue }

    /// Language, display, picture and input: what a player sets once for how the game looks and answers.
    static let gameEnvs: Set<String> = ["DM_LANG", "DM_FULLSCREEN", MacGameMode.optionEnv, "DM_PICTURE_FIT", "DM_SCREEN_ASPECT",
                                        "DM_SHOW_FPS", "DM_TOUCH_HAPTICS", "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_RUMBLE_MIN",
                                        "DM_PAD_PRESS_TO_JOIN"]
    /// Frame rate, resolution, console mode, upscaling and the engine's tuning switches.
    static let performanceEnvs: Set<String> = ["DM_FPS_TARGET", "DM_DYNAMIC_RESOLUTION", "DM_RENDER_SCALE", "DM_OPMODE", "DM_PRESENT_UPSCALE",
                                               "DM_UPSCALER", "DM_PRESENT_SNAP", "DM_PSO_MTL4", "DM_PSO_PREBUILD", "DM_NVN_ENC_THREAD",
                                               "DM_FPS_HOLD", "DM_METAL_HUD"]

    static func of(_ setting: LaunchSetting) -> LaunchCategory {
        if gameEnvs.contains(setting.env) { return .game }
        if performanceEnvs.contains(setting.env) { return .performance }
        return setting.sectionTitle == "Performance" ? .performance : .game
    }
}

/// What a game can be set up for from this Mac. Mac settings are drawn only for a Mac build. A game that only has an iPhone or iPad build
/// shows the actions that apply to it from the Mac, and a game with neither shows one explanation and the way to build it.
enum LaunchDestination: Equatable {
    case mac, ios, none

    init(_ game: LibraryGame) {
        self = game.isReady ? .mac : (game.hasIOSBuild || game.onDevice ? .ios : .none)
    }

    /// The parts the selector offers.
    var categories: [LaunchCategory] {
        switch self {
        case .mac: return LaunchCategory.allCases
        case .ios: return [.mods, .saves]
        case .none: return []
        }
    }
}
