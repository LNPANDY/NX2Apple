import Foundation
import GameController
import CoreHaptics
import os

/// Identify (the player lights, the light bar, a rumble) and the controller settings page's rumble test: what a game's rumble feels like at its strength, before the game is started.
extension LiveConsoleDriver {
    /// Everything the controller has: its player lights step through 1 to 4, the light bar pulses, it rumbles. The assigned player
    /// and the light's colour are restored after. Presses while it runs only show the toast again.
    func identify(controllerID: String) {
        guard let c = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.identifyingControllerID = controllerID
        showToast(String(format: t("console.identifyingName"), c.name))
        guard identifyRunning != controllerID, let pad = devices[controllerID] else { return }
        let actions = Self.identifyActions(pad)
        Self.identifyLog.debug("identify \(c.name, privacy: .public): \(actions.map { "\($0)" }.joined(separator: ","), privacy: .public)")
        identifyTask?.cancel()
        if let previous = identifyRunning { stopRumble(previous) }
        identifyRunning = controllerID
        identifyTask = Task { [weak self] in
            let player = pad.playerIndex
            let color = pad.light?.color
            if actions.contains(.rumble) { self?.rumble(pad, id: controllerID) }
            for step in 0..<8 {
                guard !Task.isCancelled else { break }
                if actions.contains(.playerLights) { pad.playerIndex = GCControllerPlayerIndex(rawValue: step % 4) ?? .indexUnset }
                if actions.contains(.lightBar) { pad.light?.color = step % 2 == 0 ? GCColor(red: 1, green: 0.1, blue: 0.9) : GCColor(red: 0.1, green: 0.9, blue: 1) }
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
            pad.playerIndex = player
            if let color { pad.light?.color = color }
            if self?.identifyRunning == controllerID { self?.identifyRunning = nil }
        }
    }

    func rumble(_ pad: GCController, id: String, intensity: Float = 1) {
        stopRumble(id)
        guard let engine = identifyEngines[id] ?? makeEngine(pad, id: id) else { return }
        identifyEngines[id] = engine
        do {
            try engine.start()
            let events = [CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                                                                  CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)],
                                        relativeTime: 0, duration: Self.rumbleSeconds)]
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            identifyPlayers[id] = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch { Self.identifyLog.debug("identify: rumble failed: \(error.localizedDescription, privacy: .public)") }
        rumbleStops[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.rumbleSeconds + 0.1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopRumble(id)
        }
    }

    func makeEngine(_ pad: GCController, id: String) -> CHHapticEngine? {
        guard let haptics = pad.haptics else { Self.identifyLog.debug("identify: no haptics on this controller"); return nil }
        let localities: [GCHapticsLocality]
        if id.hasSuffix(".L") {
            localities = [.leftHandle, .default, .all, .handles]
        } else if id.hasSuffix(".R") {
            localities = [.rightHandle, .default, .all, .handles]
        } else {
            localities = [.default, .all, .handles, .leftHandle, .rightHandle]
        }
        guard let engine = localities.lazy.compactMap({ haptics.createEngine(withLocality: $0) }).first else {
            Self.identifyLog.debug("identify: haptics exist but no engine could be created (supported localities: \(haptics.supportedLocalities.map(\.rawValue).joined(separator: ","), privacy: .public))")
            return nil
        }
        engine.isAutoShutdownEnabled = false   // stopped by hand after each rumble, below
        return engine
    }

    /// Ends this controller's rumble now: its player and its engine stop, and the motor with them. The engine is kept for the next one.
    func stopRumble(_ id: String) {
        rumbleStops.removeValue(forKey: id)?.cancel()
        try? identifyPlayers.removeValue(forKey: id)?.stop(atTime: CHHapticTimeImmediate)
        identifyEngines[id]?.stop(completionHandler: nil)
    }


    /// A short rumble on every connected controller that has one, at the game's DM_RUMBLE_GAIN over a middling game's level
    /// (the host multiplies what a game asks for by the gain, haptics_apple.m). With the game's rumble off, a toast says so instead.
    func testRumble(gameID: String) {
        guard let game = state.games.first(where: { $0.id == gameID }) else { return }
        let rumble = game.controllerSettings.first { $0.env == "DM_RUMBLE" }
        if let rumble, game.value(rumble) != rumble.onValue { showToast(t("console.gamePad.rumbleOff")); return }
        let gain = game.controllerSettings.first { $0.env == "DM_RUMBLE_GAIN" }.flatMap { Double(game.value($0)) } ?? 1
        let intensity = Float(Self.testIntensity(gain: gain))
        let pads = devices.filter { $0.value.haptics != nil }
        guard !pads.isEmpty else { showToast(t("console.gamePad.noRumble")); return }
        guard intensity > 0 else { return }
        for (id, pad) in pads { self.rumble(pad, id: id, intensity: intensity) }
    }

    /// The test's level: half of full, as a game's ordinary rumble, times the gain, at most full.
    nonisolated static func testIntensity(gain: Double) -> Double { min(max(gain, 0) * 0.5, 1) }
}
