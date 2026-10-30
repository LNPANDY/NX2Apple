import Foundation
import ShellUI

/// The host layer's own words, from `Resources/Localizable.xcstrings` (English source, like ShellUI).
func hostText(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// What is wrong with a bundle that cannot run at all. Each cause has one plain sentence for the player.
public enum ProblemCause: Equatable, Sendable {
    case manifestMissing, manifestDamaged, manifestUnsupported
    case settingsMissing, settingsDamaged, settingsUnsupported
    case codeMissing
    case filesDamaged

    /// What happened and what to do, for the player. The technical message stays in `GameProblem.detail`.
    public var message: String {
        switch self {
        case .manifestMissing: hostText("This game's manifest is missing. Rebuild the game in the launcher on your Mac.")
        case .manifestDamaged: hostText("This game's manifest is damaged. Rebuild the game in the launcher on your Mac.")
        case .manifestUnsupported, .settingsUnsupported:
            hostText("This game was built for a different version of this app. Update the app or rebuild the game in the launcher on your Mac.")
        case .settingsMissing: hostText("This game's settings list is missing. Rebuild the game in the launcher on your Mac.")
        case .settingsDamaged: hostText("This game's settings list is damaged. Rebuild the game in the launcher on your Mac.")
        case .codeMissing: hostText("The game's code is missing from this app. Rebuild and reinstall it.")
        case .filesDamaged: hostText("This game's files are damaged. Rebuild the game in the launcher on your Mac.")
        }
    }
}

/// Why a game cannot be shown as playable: `reason` is the short line under the title, `cause` says which of the
/// known problems it is, `detail` is the technical message (logged and shown as Details, never as the hero text).
/// `reason` and `detail` are already localized.
public struct GameProblem: Error, Equatable, Sendable, LocalizedError {
    public var cause: ProblemCause
    public var reason: String
    public var detail: String
    public init(cause: ProblemCause = .filesDamaged, reason: String, detail: String = "") {
        self.cause = cause; self.reason = reason; self.detail = detail
    }
    public var errorDescription: String? { detail.isEmpty ? reason : "\(reason): \(detail)" }

    /// The broken state a tile shows: the short reason, the player's sentence and the technical message.
    public var state: GameState { .broken(reason: reason, detail: cause.message, technical: detail) }
}
