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

    @Test func padMergePersistsInShellSettingsStoreAndProducesDMPadMerge() {
        let suite = "shellui.padmerge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

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

    @Test func cloudConflictAndRestoreBackupLayersIsolateControllerFocus() {
        #expect(!LibraryView.optionsOpensShellSettings(under: .restoreBackup))
        #expect(!LibraryView.optionsOpensShellSettings(under: .cloudConflict))
        #expect(FocusLayer.restoreBackup.prefix == "rst.")
        #expect(FocusLayer.cloudConflict.prefix == "cld.")
        #expect(FocusLayer.isLive("rst.confirm", under: .restoreBackup))
        #expect(!FocusLayer.isLive("set.play", under: .restoreBackup))
        #expect(FocusLayer.isLive("cld.cloud", under: .cloudConflict))
        #expect(!FocusLayer.isLive("lib.play", under: .cloudConflict))
    }

    @Test func signingWarningBannerResolvesDistinctTitlesAcrossStates() {
        let hours = SigningWarningBanner(warning: .expiringHours(24), onDismiss: {})
        let soon = SigningWarningBanner(warning: .expiringSoon, onDismiss: {})
        let expired = SigningWarningBanner(warning: .expired, onDismiss: {})
        _ = (hours, soon, expired)
        #expect(SigningWarning.expiringHours(24) != SigningWarning.expiringSoon)
        #expect(SigningWarning.expiringSoon != SigningWarning.expired)
    }
}
