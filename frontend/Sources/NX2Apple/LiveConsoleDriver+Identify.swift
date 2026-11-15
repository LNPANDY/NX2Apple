import GameController
import CoreHaptics
import os

/// Identify (the player lights, the light bar, a rumble) of a controller in the console mode, split from LiveConsoleDriver.swift.
/// Its source is Haseenesss's #901 (one run at a time, the motor stopped by hand, the real player and light restored).
extension LiveConsoleDriver {
    /// Everything the controller has: its player lights step through 1 to 4, the light bar pulses, it rumbles. The assigned player
    /// and the light's colour are restored after. Presses while it runs only show the toast again.
    func identify(controllerID: String) {
        guard let c = state.controllers.first(where: { $0.id == controllerID }) else { return }
        state.identifyingControllerID = controllerID
        showToast(String(format: t("console.identifyingName"), c.name), kind: "controller")
        guard identifyRunning != controllerID, let pad = devices[controllerID] else { return }
        let actions = Self.identifyActions(pad)
        Self.log.debug("identify \(c.name, privacy: .public): \(actions.map { "\($0)" }.joined(separator: ","), privacy: .public)")
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
        } catch { Self.log.debug("identify: rumble failed: \(error.localizedDescription, privacy: .public)") }
        rumbleStops[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.rumbleSeconds + 0.1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopRumble(id)
        }
    }

    func makeEngine(_ pad: GCController, id: String) -> CHHapticEngine? {
        guard let haptics = pad.haptics else { Self.log.debug("identify: no haptics on this controller"); return nil }
        let localities: [GCHapticsLocality] = [.default, .all, .handles, .leftHandle, .rightHandle]
        guard let engine = localities.lazy.compactMap({ haptics.createEngine(withLocality: $0) }).first else {
            Self.log.debug("identify: haptics exist but no engine could be created (supported localities: \(haptics.supportedLocalities.map(\.rawValue).joined(separator: ","), privacy: .public))")
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
}
