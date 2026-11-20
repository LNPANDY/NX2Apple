import SwiftUI

/// The rows of the shell settings, in the game settings' own model so the same controls draw them. The game ID tells
/// the library that a change belongs to the shell and not to a game.
enum ShellSettingsRows {
    static let gameID = "shell"
    static let hud = "shell.hud"
    static let showFPS = "shell.showFPS"
    static let audioMix = "shell.audioMix"
    static let touchSize = "shell.touchSize"
    static let touchStick = "shell.touchStick"
    static let targetPrefix = "shs.row."

    static func hudRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: hud, label: ShellStrings.text("Performance overlay"), note: ShellStrings.text("Used by games that have no choice of their own."),
                   kind: .toggle(on: "1", off: "0"), value: store.performanceHUD == true ? "1" : "0")
    }

    static func showFPSRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: showFPS, label: ShellStrings.text("Frame-rate counter"), note: ShellStrings.text("Used by games that have no choice of their own."),
                   kind: .toggle(on: "1", off: "0"), value: store.showFPS == true ? "1" : "0")
    }

    static func audioMixRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: audioMix, label: ShellStrings.text("Play with other audio"),
                   note: ShellStrings.text("Allow other apps to keep playing audio alongside games."),
                   kind: .toggle(on: "1", off: "0"), value: store.audioMix ? "1" : "0")
    }

    /// The shell-wide default size for touch controls. The preview above the row shows it.
    static func touchSizeRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: touchSize, label: ShellStrings.text("Size"),
                   kind: .choice([SettingOption("small", ShellStrings.text("Small")), SettingOption("medium", ShellStrings.text("Medium")),
                                  SettingOption("large", ShellStrings.text("Large"))]),
                   value: store.touchSize)
    }

    /// The shell-wide default for the left stick's place. The buttons on the right keep their base placement.
    static func touchStickRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: touchStick, label: ShellStrings.text("Left stick"),
                   kind: .choice([SettingOption("corner", ShellStrings.text("Corner")), SettingOption("higher", ShellStrings.text("Higher")),
                                  SettingOption("inward", ShellStrings.text("Inward"))]),
                   value: store.touchStick)
    }

    /// Under the preview and in the editor options: these are shell-wide defaults that game settings or configuration files can override.
    static var touchNote: String { ShellStrings.text("Games and configuration files can override these defaults.") }

    /// A change of one of the rows, from the row itself or from the list of choices.
    static func apply(_ id: String, value: String, to store: ShellSettingsStore) {
        switch id {
        case hud: store.storePerformanceHUD(value == "1")
        case showFPS: store.storeShowFPS(value == "1")
        case audioMix: store.storeAudioMix(value == "1")
        case touchSize: store.storeTouchSize(value)
        case touchStick: store.storeTouchStick(value)
        default: break
        }
    }
}

/// Native grouped settings for shell-wide defaults; per-game choices retain precedence.
struct ShellSettingsView: View {
    @Environment(\.shellNativeBars) private var nativeBars
    var store: ShellSettingsStore = .current
    var actions: ShellActions
    var sideloadCertificate: SideloadCertificateSummary? = nil
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellFocus) private var focus
    /// Counts the changes in the defaults, so the rows read the store again.
    @State private var revision = 0
    @State private var pendingCertFileName: String?
    @State private var certPromptPresented = false
    @State private var certConfirming = false
    @State private var certPassword = ""
    @State private var certImportError: String?
    @State private var certBusy = false

    var body: some View {
        let _ = revision
        ScrollViewReader { proxy in
            Form {
                if !nativeBars {
                    Section {
                        LabeledContent(ShellStrings.text("Settings")) {
                            Button(ShellStrings.text("Close"), action: onClose)
                                .accessibilityIdentifier("shellSettings.close")
                                .shellTarget("shs.close", action: onClose)
                        }
                    }.id("shs.top")
                }

                Section {
                    Button(action: actions.onPickShellData) {
                        LabeledContent {
                            Text(store.dataFolderName ?? ShellStrings.text("Choose folder…"))
                                .lineLimit(1).truncationMode(.middle)
                        } label: {
                            Label(ShellStrings.text("Game data"), systemImage: "folder")
                                .labelStyle(SettingsRowLabelStyle())
                        }
                    }
                    .accessibilityIdentifier("shellSettings.data")
                    .shellTarget("shs.data", action: actions.onPickShellData)
                    if store.dataFolderName != nil {
                        Button(ShellStrings.text("Remove"), role: .destructive, action: actions.onClearShellData)
                            .accessibilityIdentifier("shellSettings.data.remove")
                            .shellTarget("shs.data.remove", action: actions.onClearShellData)
                    }
                } footer: {
                    Text(ShellStrings.text("Games look for their data here. Keep one romfs.img per game in any folder inside. Each game is found by the image itself, so the folder names do not matter. Each game can also have a folder of its own."))
                }

                Section {
                    Button(action: actions.onPickShellCloud) {
                        LabeledContent {
                            Text(store.cloudSavesFolderName ?? ShellStrings.text("Choose folder…"))
                                .lineLimit(1).truncationMode(.middle)
                        } label: {
                            Label(ShellStrings.text(store.cloudSavesFolderName == nil ? "Enable Cloud saves" : "Cloud saves to"), systemImage: "icloud")
                                .labelStyle(SettingsRowLabelStyle())
                        }
                    }
                    .accessibilityIdentifier("shellSettings.cloud")
                    .shellTarget("shs.cloud", action: actions.onPickShellCloud)
                    if store.cloudSavesFolderName != nil {
                        Button(ShellStrings.text("Turn off"), role: .destructive, action: actions.onClearShellCloud)
                            .accessibilityIdentifier("shellSettings.cloud.off")
                            .accessibilityLabel(ShellStrings.text("Turn off cloud saves"))
                            .shellTarget("shs.cloud.off", action: actions.onClearShellCloud)
                    }
                } footer: {
                    Text(ShellStrings.text("Games without a folder of their own save here. Choose the same iCloud Drive folder you use on your Mac."))
                }

                Section {
                    TouchArrangeRow(arranged: !store.touchLayout.isEmpty)
                }

                if actions.supportsSideloadCertificate || sideloadCertificate != nil {
                    sideloadCertificateSection
                }

                Section {
                    Toggle(isOn: Binding(get: { store.audioMix }, set: { on in
                        store.storeAudioMix(on)
                        revision += 1
                    })) {
                        Label(ShellStrings.text("Play with other audio"), systemImage: "speaker.wave.2")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .toggleStyle(NativeCreamToggleStyle())
                    .accessibilityIdentifier("setting.shell.audioMix")
                    .shellTarget("shs.row.\(ShellSettingsRows.audioMix)") {
                        store.storeAudioMix(!store.audioMix)
                        revision += 1
                    }
                } header: {
                    Text(ShellStrings.text("Sound"))
                } footer: {
                    Text(ShellStrings.text("Allow other apps to keep playing audio alongside games."))
                }

                Section {
                    Toggle(isOn: Binding(get: { store.performanceHUD == true }, set: { store.storePerformanceHUD($0); revision += 1 })) {
                        Label(ShellStrings.text("Performance overlay"), systemImage: "speedometer")
                                .labelStyle(SettingsRowLabelStyle())
                    }
                    .toggleStyle(NativeCreamToggleStyle())
                    .accessibilityIdentifier("setting.shell.hud")
                    .shellTarget("shs.row.\(ShellSettingsRows.hud)") {
                        store.storePerformanceHUD(store.performanceHUD != true)
                        revision += 1
                    }
                    Toggle(isOn: Binding(get: { store.showFPS == true }, set: { store.storeShowFPS($0); revision += 1 })) {
                        Label(ShellStrings.text("Frame-rate counter"), systemImage: "number")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .toggleStyle(NativeCreamToggleStyle())
                    .accessibilityIdentifier("setting.shell.showFPS")
                    .shellTarget("shs.row.\(ShellSettingsRows.showFPS)") {
                        store.storeShowFPS(store.showFPS != true)
                        revision += 1
                    }
                } header: {
                    Text(ShellStrings.text("Interface"))
                } footer: {
                    Text(ShellStrings.text("Used by games that have no choice of their own."))
                }
            }
            .formStyle(.grouped)
            .labelStyle(SettingsRowLabelStyle())
            .scrollContentBackground(.hidden)
            .background(ShellPalette.background)
            .onChange(of: focus.id) { _, id in
                guard let id, id.hasPrefix("shs.") else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(id == "shs.close" ? "shs.top" : id, anchor: id == "shs.close" ? .top : .center)
                }
            }
        }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in revision += 1 }
        .alert(
            Text(verbatim: ShellStrings.text("Enter certificate password")),
            isPresented: Binding(
                get: { certPromptPresented },
                set: { presented in
                    certPromptPresented = presented
                    if !presented {
                        scheduleCancelIfNotConfirmed()
                    }
                }
            )
        ) {
            SecureField(ShellStrings.text("Certificate password"), text: $certPassword)
                .accessibilityIdentifier("shellSettings.sideloadCert.passwordField")
            Button(ShellStrings.text("Import")) {
                confirmCertificatePassword()
            }
            .accessibilityIdentifier("shellSettings.sideloadCert.passwordConfirm")
            Button(ShellStrings.text("Cancel"), role: .cancel) {
                cancelCertificatePasswordPrompt()
            }
        } message: {
            if let fileName = pendingCertFileName {
                Text(verbatim: ShellStrings.text("Enter the password for \(fileName). Leave it blank if the certificate has no password."))
            }
        }
        .alert(
            Text(verbatim: ShellStrings.text("Certificate import failed")),
            isPresented: Binding(
                get: { certImportError != nil },
                set: { if !$0 { certImportError = nil } }
            )
        ) {
            Button(ShellStrings.text("Close")) { certImportError = nil }
        } message: {
            Text(verbatim: certImportError ?? "")
        }
    }

    @ViewBuilder
    private var sideloadCertificateSection: some View {
        Section {
            if let cert = sideloadCertificate {
                LabeledContent {
                    Text(cert.commonName.isEmpty ? cert.fingerprintHex.prefix(16).uppercased() : cert.commonName)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label(ShellStrings.text("Certificate"), systemImage: "checkmark.seal")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("shellSettings.sideloadCert.name")

                if !cert.teamID.isEmpty {
                    LabeledContent(ShellStrings.text("Signing team"), value: cert.teamID)
                        .accessibilityIdentifier("shellSettings.sideloadCert.team")
                }

                if let expiresAt = cert.expiresAt {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(Self.formatCertificateDate(expiresAt))
                                .foregroundStyle(cert.isExpired ? .red : .secondary)
                            if cert.isExpired {
                                Text(ShellStrings.text("Expired"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                            }
                        }
                    } label: {
                        Text(ShellStrings.text("Valid until"))
                    }
                    .accessibilityIdentifier("shellSettings.sideloadCert.expiry")
                }

                if actions.supportsSideloadCertificate {
                    Button(action: startCertificateImport) {
                        Label(ShellStrings.text("Replace certificate"), systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .disabled(certBusy)
                    .accessibilityIdentifier("shellSettings.sideloadCert.replace")
                    .shellTarget("shs.sideloadCert.replace", action: startCertificateImport)
                }

                if let onRemove = actions.onRemoveSideloadCertificate {
                    Button(ShellStrings.text("Remove certificate"), role: .destructive, action: onRemove)
                        .disabled(certBusy)
                        .accessibilityIdentifier("shellSettings.sideloadCert.remove")
                        .shellTarget("shs.sideloadCert.remove", action: onRemove)
                }
            } else {
                LabeledContent {
                    Text(ShellStrings.text("Not configured"))
                        .foregroundStyle(.secondary)
                } label: {
                    Label(ShellStrings.text("Certificate status"), systemImage: "signature")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .accessibilityIdentifier("shellSettings.sideloadCert.status")

                if actions.supportsSideloadCertificate {
                    Button(action: startCertificateImport) {
                        Label(ShellStrings.text("Import .p12 certificate"), systemImage: "doc.badge.plus")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .disabled(certBusy)
                    .accessibilityIdentifier("shellSettings.sideloadCert.import")
                    .shellTarget("shs.sideloadCert.import", action: startCertificateImport)
                }
            }
        } header: {
            Text(ShellStrings.text("Sideload signing certificate"))
        } footer: {
            Text(ShellStrings.text("When NX2Apple is installed through SideStore, AltStore, or another sideload tool, import the .p12 certificate exported by that tool here so unsigned game frameworks placed in Frameworks are signed automatically on launch. Installs directly from Xcode on a Mac do not need this."))
        }
    }

    private func startCertificateImport() {
        guard !certBusy, let pickFile = actions.onPickSideloadCertificateFile else { return }
        certBusy = true
        Task {
            let outcome = await pickFile()
            certBusy = false
            switch outcome {
            case .picked(let fileName):
                certPassword = ""
                certConfirming = false
                pendingCertFileName = fileName
                certPromptPresented = true
            case .cancelled:
                break
            case .failed(let message):
                certImportError = message
            }
        }
    }

    private func confirmCertificatePassword() {
        guard !certBusy, let confirm = actions.onConfirmSideloadCertificatePassword else {
            cancelCertificatePasswordPrompt()
            return
        }
        // Mark confirming before clearing prompt state so SwiftUI's `isPresented.set(false)` can never race
        // and discard the entered password or the host's staged `.p12` bytes.
        certConfirming = true
        let password = certPassword
        certPassword = ""
        pendingCertFileName = nil
        certPromptPresented = false
        certBusy = true
        Task {
            let failure = await confirm(password)
            certBusy = false
            certConfirming = false
            if let failure, !failure.isEmpty {
                certImportError = failure
            }
        }
    }

    private func scheduleCancelIfNotConfirmed() {
        // Defer one MainActor turn so if SwiftUI toggles `isPresented` before firing the `Import` button action,
        // `confirmCertificatePassword()` sets `certConfirming = true` before any cleanup runs.
        Task { @MainActor in
            await Task.yield()
            if !certConfirming && !certPromptPresented && pendingCertFileName != nil {
                cancelCertificatePasswordPrompt()
            }
        }
    }

    private func cancelCertificatePasswordPrompt() {
        certConfirming = false
        certPassword = ""
        pendingCertFileName = nil
        certPromptPresented = false
        actions.onCancelSideloadCertificateImport?()
    }

    private static func formatCertificateDate(_ date: Date) -> String {
        let locale: Locale
        if let code = ShellStrings.captureBundle?.bundleURL.deletingPathExtension().lastPathComponent, !code.isEmpty {
            locale = Locale(identifier: code)
        } else {
            locale = .autoupdatingCurrent
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }
}

struct SettingsRowLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconSize = 30

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.body.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: iconSize, height: iconSize)
                .background(ShellPalette.cream, in: RoundedRectangle(cornerRadius: iconSize * 0.23))
                .accessibilityHidden(true)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}
