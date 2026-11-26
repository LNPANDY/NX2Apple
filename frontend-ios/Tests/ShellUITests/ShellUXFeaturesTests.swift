import Foundation
import Testing
@testable import ShellUI

@MainActor @Suite struct ShellUXFeaturesTests {
    @Test func joiningGameDataStateCarriesProgressStringsAndLocksPlay() {
        let state = GameState.joiningGameData(percent: 45, doneSize: "2.3 GB", totalSize: "5.1 GB")
        #expect(state.isJoining)
        #expect(!GameState.needsGameData.isJoining)
        #expect(!GameState.playable.isJoining)
        #expect(state.artworkWarning == "Joining Data")
        #expect(state.title == "Joining game data (45%)")
        #expect(state.actionTitle == "Joining game data (45%)")
        #expect(state.explanation.contains("2.3 GB"))
        #expect(state.explanation.contains("5.1 GB"))
    }

    @Test func dataUpdateStatesSayWhatToDo() {
        for stale in [false, true] {
            let text = GameState.needsDataUpdate(staleChain: stale).explanation
            #expect(text.contains("romfs.img"))
        }
        #expect(GameState.playable.explanation.isEmpty)
    }

    @Test func padMergePersistsInShellSettingsStoreAndProducesDMPadMerge() {
        let defaults = TestDefaults.make("shellui-padmerge")

        let store = ShellSettingsStore(defaults: defaults)
        #expect(!store.padMerge)
        #expect(store.gameDefaults["DM_PAD_MERGE"] == nil)

        store.storePadMerge(true)
        #expect(store.padMerge)
        #expect(store.gameDefaults["DM_PAD_MERGE"] == "1")
        #expect(ShellSettingsStore(defaults: defaults).padMerge)

        store.storePadMerge(false)
        #expect(!store.padMerge)
        #expect(store.gameDefaults["DM_PAD_MERGE"] == nil)
    }

    @Test func audioMixPersistsInShellSettingsStoreAndProducesDMAudioMix() {
        let defaults = TestDefaults.make("shellui-audiomix")

        let store = ShellSettingsStore(defaults: defaults)
        #expect(!store.audioMix)
        #expect(store.gameDefaults["DM_AUDIO_MIX"] == nil)
        #expect(ShellSettingsRows.audioMixRow(store).value == "0")

        ShellSettingsRows.apply(ShellSettingsRows.audioMix, value: "1", to: store)
        #expect(store.audioMix)
        #expect(store.gameDefaults["DM_AUDIO_MIX"] == "1")
        #expect(ShellSettingsRows.audioMixRow(store).value == "1")
        #expect(ShellSettingsStore(defaults: defaults).audioMix)

        ShellSettingsRows.apply(ShellSettingsRows.audioMix, value: "0", to: store)
        #expect(!store.audioMix)
        #expect(store.gameDefaults["DM_AUDIO_MIX"] == nil)
        #expect(defaults.object(forKey: ShellSettingsStore.audioMixKey) == nil)
    }

    @Test
    func showFPSPersistsInShellSettingsStoreAndProducesDMShowFPS() {
        let defaults = TestDefaults.make("shellui-ux")

        let store = ShellSettingsStore(defaults: defaults)
        #expect(store.showFPS == nil)
        #expect(store.gameDefaults["DM_SHOW_FPS"] == nil)

        store.storeShowFPS(true)
        #expect(store.showFPS == true)
        #expect(store.gameDefaults["DM_SHOW_FPS"] == "1")
        #expect(ShellSettingsRows.showFPSRow(store).value == "1")
        #expect(defaults.object(forKey: ShellSettingsStore.showFPSKey) as? Bool == true)

        ShellSettingsRows.apply(ShellSettingsRows.showFPS, value: "0", to: store)
        #expect(store.showFPS == false)
        #expect(store.gameDefaults["DM_SHOW_FPS"] == "0")
        #expect(defaults.object(forKey: ShellSettingsStore.showFPSKey) as? Bool == false)

        let row = ShellSettingsRows.showFPSRow(store)
        #expect(row.id == ShellSettingsRows.showFPS)
        #expect(row.value == "0")
    }

    @Test func cloudConflictAndRestoreBackupLayersIsolateControllerFocus() {
        #expect(!LibraryView.optionsOpensShellSettings(under: .restoreBackup))
        #expect(!LibraryView.optionsOpensShellSettings(under: .cloudConflict))
        #expect(!LibraryView.optionsOpensShellSettings(under: .saveImport))
        #expect(FocusLayer.restoreBackup.prefix == "rst.")
        #expect(FocusLayer.cloudConflict.prefix == "cld.")
        #expect(FocusLayer.saveImport.prefix == "svi.")
        #expect(FocusLayer.isLive("rst.confirm", under: .restoreBackup))
        #expect(!FocusLayer.isLive("set.play", under: .restoreBackup))
        #expect(FocusLayer.isLive("cld.cloud", under: .cloudConflict))
        #expect(!FocusLayer.isLive("lib.play", under: .cloudConflict))
        #expect(FocusLayer.isLive("svi.confirm", under: .saveImport))
        #expect(FocusLayer.isLive("svi.mode.merge", under: .saveImport))
        #expect(!FocusLayer.isLive("set.save.import", under: .saveImport))
    }

    @Test func saveImportConfirmViewBuildsForExistingAndFreshSaves() {
        let existingPrompt = SaveImportPrompt(
            gameID: "0100000000010000",
            gameTitle: "Orbit",
            sourceName: "Orbit [0100000000010000].zip",
            sourceKind: .jksvArchive,
            fileCount: 3,
            totalBytes: 4096,
            formattedSize: "4 KB",
            jksvTitleID: "0100000000010000",
            targetFolders: ["save"],
            hasExistingSave: true,
            defaultMode: .replace
        )
        let freshPrompt = SaveImportPrompt(
            gameID: "0100000000010000",
            gameTitle: "Orbit",
            sourceName: "Farm_335352527",
            sourceKind: .singleFile,
            fileCount: 1,
            totalBytes: 2048,
            formattedSize: "2 KB",
            hasExistingSave: false
        )
        _ = SaveImportConfirmView(prompt: existingPrompt, confirm: { _ in }, cancel: {})
        _ = SaveImportConfirmView(prompt: freshPrompt, confirm: { _ in }, cancel: {})
        let detail = GameDetail(game: GameTile(id: "0100000000010000", title: "Orbit"), hasLocalSave: true, localSaveSummary: "3 files · 4 KB")
        let actions = ShellActions(
            onPickSaveImport: { _ in .cancelled },
            onExportSave: { _ in .cancelled }
        )
        #expect(actions.supportsSaves)
        _ = GameDetailView(detail: detail, actions: actions)
    }

    @Test func signingWarningBannerResolvesDistinctTitlesAcrossStates() {
        let hours = SigningWarningBanner(warning: .expiringHours(24), onDismiss: {})
        let soon = SigningWarningBanner(warning: .expiringSoon, onDismiss: {})
        let expired = SigningWarningBanner(warning: .expired, onDismiss: {})
        _ = (hours, soon, expired)
        #expect(SigningWarning.expiringHours(24) != SigningWarning.expiringSoon)
        #expect(SigningWarning.expiringSoon != SigningWarning.expired)
    }

    @Test func emptyLibraryViewWiresOptionalOpenSettingsCallback() {
        var opened = false
        let plain = EmptyLibraryView()
        #expect(plain.onOpenSettings == nil)
        let guided = EmptyLibraryView(onOpenSettings: { opened = true })
        guided.onOpenSettings?()
        #expect(opened)
    }

    @Test @MainActor func toolbarFocusBufferOwnerPreventsStaleDisappearFromClearingLiveTarget() {
        let buffer = FocusTargetBuffer()
        let outgoingOwner = UUID()
        let liveOwner = UUID()
        var liveActivated = false
        let staleFrame = CGRect(x: 16, y: 16, width: 44, height: 44)
        let liveFrame = CGRect(x: 20, y: 20, width: 44, height: 44)

        buffer.registerToolbar(FocusTarget(id: "help.done", frame: staleFrame, activate: {}), owner: outgoingOwner)
        buffer.registerToolbar(FocusTarget(id: "help.done", frame: liveFrame, activate: { liveActivated = true }), owner: liveOwner)
        // Outgoing transition view disappears after incoming view has already registered the same key.
        buffer.unregisterToolbar(id: "help.done", owner: outgoingOwner)

        let active = buffer.active(prefix: "help.", toolbarIDs: ["help.done"])
        #expect(active.count == 1)
        #expect(active.first?.frame == liveFrame)
        active.first?.activate()
        #expect(liveActivated)

        // Live owner disappearing clears the slot cleanly.
        buffer.unregisterToolbar(id: "help.done", owner: liveOwner)
        #expect(buffer.active(prefix: "help.", toolbarIDs: ["help.done"]).isEmpty)
    }
}
