import AppKit

@MainActor enum NoticeSounds {
    static let defaultsKey = "noticeSounds"
    enum Event: Equatable { case buildFinished, buildFailed, controllerConnected, controllerDisconnected }

    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    static func name(for event: Event, enabled: Bool, gameRunning: Bool) -> String? {
        guard enabled, !gameRunning else { return nil }
        switch event {
        case .buildFinished: return "Glass"
        case .buildFailed: return "Basso"
        case .controllerConnected: return "Pop"
        case .controllerDisconnected: return "Funk"
        }
    }

    static func play(_ event: Event, startingGame: Bool = false) {
        guard let name = name(for: event, enabled: enabled, gameRunning: startingGame || GameReturnWatcher.shared.isGameRunning) else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
