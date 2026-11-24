import Combine
import Foundation
import NXCore
import NXModel

/// Question presented when enabling MNG #2375 shared `dm` saves for the first time on a title
/// whose legacy `MacNativeGames/<GAME>/profile/save/<uid>/` folder still holds save data.
struct MngMigrationQuestion: Equatable, Identifiable {
    let id = UUID()
    let titleID: String
    let gameName: String
    let appPath: String
    let assessment: MngSaveMigration.Assessment
    var busy = false
    var error: String?

    var isConflict: Bool {
        if case .bothHaveSaves = assessment { return true }
        return false
    }
}

/// Persists first-time MNG shared-save migration decisions and runs non-destructive save migration off the main thread.
@MainActor final class MngSaveMigrationCoordinator: ObservableObject {
    struct Receipt: Codable, Equatable {
        let choice: MngSaveMigration.Choice
        let signature: String
    }

    @Published var prompt: MngMigrationQuestion?
    var isActive: Bool { prompt != nil }

    private let defaults: UserDefaults
    private let support: URL
    private let isGameRunning: @Sendable (String) -> Bool
    private var generation: UInt64 = 0
    private var onProceed: (() -> Void)?
    private var onCancel: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        isGameRunning: @escaping @Sendable (String) -> Bool = { SaveTransfer.runningOnMac(titleID: $0) }
    ) {
        self.defaults = defaults
        self.support = support
        self.isGameRunning = isGameRunning
    }

    static func receiptKey(titleID: String) -> String {
        "mngSaveMigration." + titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func receipt(for titleID: String) -> Receipt? {
        guard let data = defaults.data(forKey: Self.receiptKey(titleID: titleID)) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    func saveReceipt(_ receipt: Receipt, for titleID: String) {
        if let data = try? JSONEncoder().encode(receipt) {
            defaults.set(data, forKey: Self.receiptKey(titleID: titleID))
        }
    }

    /// Returns a migration assessment when `appPath` is a #2375 MNG build and user confirmation is required,
    /// or `nil` when no legacy MNG save exists or the current state was already decided by the player.
    func assessmentIfNeeded(
        titleID: String,
        appPath: String,
        saveSettings: SaveSettingsStore
    ) -> MngSaveMigration.Assessment? {
        guard !appPath.isEmpty,
              SaveEngines.forApp(appPath, titleID: titleID) is MngSharedDmSaveEngine else {
            return nil
        }
        let assessment = MngSaveMigration.assess(
            titleID: titleID,
            appPath: appPath,
            global: saveSettings.global,
            game: saveSettings.game(titleID),
            support: support
        )
        guard assessment != .none else { return nil }
        let sig = MngSaveMigration.stateSignature(for: assessment)
        if let existing = receipt(for: titleID), existing.signature == sig {
            return nil
        }
        return assessment
    }

    /// Presents the migration sheet if needed before proceeding; otherwise invokes `proceed` immediately.
    func beginIfNeeded(
        titleID: String,
        gameName: String,
        appPath: String,
        saveSettings: SaveSettingsStore,
        proceed: @escaping () -> Void,
        cancelled: @escaping () -> Void = {}
    ) {
        guard prompt == nil else { return }
        guard let assessment = assessmentIfNeeded(titleID: titleID, appPath: appPath, saveSettings: saveSettings) else {
            proceed()
            return
        }
        generation &+= 1
        onProceed = proceed
        onCancel = cancelled
        prompt = MngMigrationQuestion(
            titleID: titleID.uppercased(),
            gameName: gameName,
            appPath: appPath,
            assessment: assessment
        )
    }

    /// Applies the player's explicit migration choice (`importMNG` or `keepNxnative`) off the main actor.
    func choose(
        _ choice: MngSaveMigration.Choice,
        saveSettings: SaveSettingsStore,
        codesign: Bool = true
    ) {
        guard var current = prompt, !current.busy else { return }
        current.busy = true
        current.error = nil
        prompt = current
        let gen = generation
        let titleID = current.titleID
        let appPath = current.appPath
        let assessment = current.assessment
        let global = saveSettings.global
        let gameOverride = saveSettings.game(titleID)
        let supportDir = support
        let runningCheck = isGameRunning

        Task {
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    _ = try MngSaveMigration.execute(
                        choice: choice,
                        assessment: assessment,
                        gameRunning: runningCheck(titleID)
                    )
                    MngAppLaunchConfig.syncIfNeeded(
                        appPath: appPath,
                        titleID: titleID,
                        global: global,
                        game: gameOverride,
                        support: supportDir,
                        isRunning: runningCheck(titleID),
                        codesign: codesign
                    )
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard generation == gen else { return }
            switch outcome {
            case .success:
                let updated = MngSaveMigration.assess(
                    titleID: titleID,
                    appPath: appPath,
                    global: global,
                    game: gameOverride,
                    support: supportDir
                )
                saveReceipt(
                    Receipt(choice: choice, signature: MngSaveMigration.stateSignature(for: updated)),
                    for: titleID
                )
                saveSettings.notifySaveChanged()
                let proceed = onProceed
                reset()
                proceed?()
            case .failure(let error):
                var next = current
                next.busy = false
                next.error = errorMessage(error, gameName: current.gameName)
                prompt = next
            }
        }
    }

    func cancel() {
        guard prompt != nil else { return }
        generation &+= 1
        let cancelled = onCancel
        reset()
        cancelled?()
    }

    private func reset() {
        prompt = nil
        onProceed = nil
        onCancel = nil
    }

    private func errorMessage(_ error: Error, gameName: String) -> String {
        switch error as? MngSaveMigration.MigrationError {
        case .gameRunning:
            return String(format: L10n.string("saves.running", Lang.initial()), gameName)
        case .volumeCannotHoldSaves:
            return L10n.string("savesloc.volume", Lang.initial())
        case .sourceMissing:
            return L10n.string("savesloc.nothingToImport", Lang.initial())
        case .copyFailed, .backupFailed, nil:
            return error.localizedDescription
        }
    }
}
