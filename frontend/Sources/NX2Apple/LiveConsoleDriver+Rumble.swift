import Foundation
import GameController

/// The controller settings page's rumble test (Identify and the rumble itself are in LiveConsoleDriver+Identify.swift): what a game's rumble feels like at its strength, before the game is started.
extension LiveConsoleDriver {
    /// A short rumble on every connected controller that has one, at the game's DM_RUMBLE_GAIN over a middling game's level
    /// (the host multiplies what a game asks for by the gain, haptics_apple.m). With the game's rumble off, a toast says so instead.
    func testRumble(gameID: String) {
        guard let game = state.games.first(where: { $0.id == gameID }) else { return }
        let rumble = game.controllerSettings.first { $0.env == "DM_RUMBLE" }
        if let rumble, game.value(rumble) != rumble.onValue { showToast(t("console.gamePad.rumbleOff"), kind: "controller"); return }
        let gain = game.controllerSettings.first { $0.env == "DM_RUMBLE_GAIN" }.flatMap { Double(game.value($0)) } ?? 1
        let intensity = Float(Self.testIntensity(gain: gain))
        let pads = devices.filter { $0.value.haptics != nil }
        guard !pads.isEmpty else { showToast(t("console.gamePad.noRumble"), kind: "controller"); return }
        guard intensity > 0 else { return }
        for (id, pad) in pads { self.rumble(pad, id: id, intensity: intensity) }
    }

    /// The test's level: half of full, as a game's ordinary rumble, times the gain, at most full.
    nonisolated static func testIntensity(gain: Double) -> Double { min(max(gain, 0) * 0.5, 1) }
}
