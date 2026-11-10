import Combine
import NXCore

/// The console mode's side of the check before a start (#957, CloudSaveGate.swift): the download shows on the Starting screen,
/// where B cancels it and, once it takes long, A plays with this Mac's save; the question is a sheet whose buttons a controller
/// reaches. An answer starts the game the question was about.
extension LiveConsoleDriver {
    func watchCloudGate() {
        cloudWatch = cloudGate.$step.sink { [weak self] step in
            MainActor.assumeIsolated { self?.show(step) }
        }
    }

    private func show(_ step: CloudSaveStep?) {
        switch step {
        case let .fetching(_, long): if state.startingGameID != nil { state.starting = .cloudSave(long: long) }
        case let .asking(question): state.askCloudSave(question)
        case nil: break
        }
    }

    /// Starting comes back for the game, then the gate starts it with the answer (its `proceed`, in `play`).
    func chooseCloudSave(_ choice: CloudSaveCheck.Choice) {
        guard cloudGate.isActive, let id = cloudGameID else { return }
        if case .asking = cloudGate.step { state.play(id) }
        cloudGate.choose(choice)
    }

    func retryCloudSave() {
        guard case .asking = cloudGate.step, let id = cloudGameID else { return }
        state.play(id)
        cloudGate.retry()
    }
}
