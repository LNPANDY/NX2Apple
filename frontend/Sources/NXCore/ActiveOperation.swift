import Foundation

/// The work the launcher is doing right now (LNPANDY/NX2Apple#676, #1059): which operation, on which game, for which destination.
/// It is a fact of the running work, taken when the work starts. It never follows the Build form, so picking another game in the
/// form, or a form target that differs, cannot rename or retarget what runs.
package struct ActiveOperation: Equatable, Sendable {
    package enum Kind: String, Sendable, CaseIterable {
        case building, verifyingFirstStart, exportingIPA, installing, renewingSignature, sendingGameData

        /// The localization key of the operation's name ("Building", "Verifying first start", ...).
        package var key: String { "op.\(rawValue)" }
        /// A game build (the library marks the game as being built), as opposed to an action on the shared app or its data.
        package var buildsGame: Bool { self == .building || self == .verifyingFirstStart }
    }

    package enum Destination: Equatable, Sendable {
        case thisMac
        case device(String)   // the device's own name
        case folder(String)   // a folder or drive the game data is copied to
    }

    package var kind: Kind
    /// The game the work is about, nil for work on the shared app as a whole (a re-sign).
    package var game: String?
    package var titleID: String?
    package var destination: Destination?

    package init(kind: Kind, game: String? = nil, titleID: String? = nil, destination: Destination? = nil) {
        self.kind = kind; self.game = game; self.titleID = titleID; self.destination = destination
    }

    /// "<operation> · <game> · <destination>" with the parts that are known. `thisMac` is the localized "This Mac".
    package func title(_ t: (String) -> String) -> String {
        var parts = [t(kind.key)]
        if let game, !game.isEmpty { parts.append(game) }
        switch destination {
        case .thisMac: parts.append(t("op.thisMac"))
        case .device(let name), .folder(let name): if !name.isEmpty { parts.append(name) }
        case nil: break
        }
        return parts.joined(separator: " · ")
    }
}
