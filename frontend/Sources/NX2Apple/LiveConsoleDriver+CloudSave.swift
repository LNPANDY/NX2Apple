import Combine
import NXCore
import NXModel

/// The console mode's side of the check before a start (#957, CloudSaveGate.swift): the download shows on the Starting screen,
/// where B cancels it and, once it takes long, A plays with this Mac's save; the question is a sheet whose buttons a controller
/// reaches. An answer starts the game the question was about.
extension LiveConsoleDriver {
    func watchCloudGate() {
        cloudWatch = cloudGate.$step.sink { [weak self] step in
            MainActor.assumeIsolated { self?.show(step) }
        }
    }

    func watchMngMigration() {
        mngMigrationWatch = mngMigration.$prompt.sink { [weak self] prompt in
            MainActor.assumeIsolated {
                guard let self, let prompt, !prompt.busy else { return }
                self.state.askMngMigration(prompt)
            }
        }
    }

    private func resolvedSaveSettings() -> SaveSettingsStore {
        mngSaveSettings ?? SaveSettingsStore(defaults: library.defaults)
    }

    func beginAfterMngMigration(game: LibraryGame, gameID: String, generation: UInt64, proceed: @escaping () -> Void) {
        let store = resolvedSaveSettings()
        mngMigrationGameID = gameID
        mngMigration.beginIfNeeded(
            titleID: game.titleID,
            gameName: game.displayName(lang()),
            appPath: game.appPath,
            saveSettings: store,
            proceed: { [weak self] in
                guard let self, self.launchGeneration == generation else { return }
                self.mngMigrationGameID = nil
                proceed()
            },
            cancelled: { [weak self] in
                guard let self, self.launchGeneration == generation else { return }
                self.mngMigrationGameID = nil
                self.pendingLaunchUpstreamOverride = nil
                self.state.returnFromGame()
            }
        )
    }

    func chooseMngMigration(_ choice: MngSaveMigration.Choice) {
        guard mngMigration.isActive, let id = mngMigrationGameID else { return }
        state.play(id)
        mngMigration.choose(choice, saveSettings: resolvedSaveSettings())
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
