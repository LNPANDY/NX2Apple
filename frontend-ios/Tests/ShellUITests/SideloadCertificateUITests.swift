import Foundation
import SwiftUI
import Testing
@testable import ShellUI

@MainActor @Suite struct SideloadCertificateUITests {
    @Test func shellActionsReportsSideloadCertificateSupportOnlyWhenBothCallbacksAreWired() {
        let bare = ShellActions()
        #expect(!bare.supportsSideloadCertificate)

        let pickOnly = ShellActions(onPickSideloadCertificateFile: { .cancelled })
        #expect(!pickOnly.supportsSideloadCertificate)

        let wired = ShellActions(
            onPickSideloadCertificateFile: { .picked(fileName: "sidestore.p12") },
            onConfirmSideloadCertificatePassword: { _ in nil }
        )
        #expect(wired.supportsSideloadCertificate)
    }

    @Test func shellSettingsViewBuildsUnconfiguredActiveAndExpiredCertificateStates() {
        let store = ShellSettingsStore(defaults: TestDefaults.make("sideload-ui"))
        let actions = ShellActions(
            onPickSideloadCertificateFile: { .cancelled },
            onConfirmSideloadCertificatePassword: { _ in nil },
            onCancelSideloadCertificateImport: {},
            onRemoveSideloadCertificate: {}
        )

        let unconfigured = ShellSettingsView(store: store, actions: actions, sideloadCertificate: nil, onClose: {})
        _ = unconfigured.body

        let activeSummary = SideloadCertificateSummary(
            commonName: "Apple Development: Player",
            teamID: "TEAM123456",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            isExpired: false,
            fingerprintHex: String(repeating: "a", count: 64)
        )
        let configured = ShellSettingsView(store: store, actions: actions, sideloadCertificate: activeSummary, onClose: {})
        _ = configured.body

        let expiredSummary = SideloadCertificateSummary(
            commonName: "Apple Development: Expired",
            teamID: "TEAM999999",
            expiresAt: Date(timeIntervalSince1970: 1_600_000_000),
            isExpired: true,
            fingerprintHex: String(repeating: "b", count: 64)
        )
        let expired = ShellSettingsView(store: store, actions: actions, sideloadCertificate: expiredSummary, onClose: {})
        _ = expired.body

        let library = LibraryView(games: [], actions: actions, sideloadCertificate: activeSummary)
        #expect(library.sideloadCertificate == activeSummary)
    }
}
