import SwiftUI
import ShellUI
import UniformTypeIdentifiers

/// Explicit owner-controlled import. No automatic account or keychain discovery.
public struct ShellSigningIdentityView: View {
    @State private var pkcs12: Data?
    @State private var profile: Data?
    @State private var pkcs12Filename: String?
    @State private var profileFilename: String?
    @State private var savedSummary: (team: String, expiration: Date)?
    @State private var password = ""
    @State private var selectingProfile = false
    @State private var picking = false
    @State private var saving = false
    @State private var loading = false
    @State private var saved = false
    @State private var removing = false
    @State private var message: String?
    private let store: ShellSigningIdentityStore

    public init(store: ShellSigningIdentityStore = .init()) { self.store = store }

    public var body: some View {
        Form {
            Section {
                Text(hostText("Your signing identity stays on this device. It must match the team that signed this app. Imported code still needs iOS approval."))
                if let savedSummary {
                    LabeledContent(hostText("Current signing team"), value: savedSummary.team)
                        .accessibilityIdentifier("signing.currentTeam")
                    LabeledContent {
                        Text(savedSummary.expiration.formatted(date: .abbreviated, time: .omitted))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.leading, 12)
                    } label: {
                        Text(hostText("Provisioning profile valid until"))
                    }
                    .accessibilityIdentifier("signing.profileExpiration")
                } else {
                    Text(saved ? hostText("Saved signing identity details unavailable") : hostText("No signing identity saved"))
                }
            }
            Section {
                Button {
                    selectingProfile = false; picking = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hostText("Choose P12 certificate"))
                        if let pkcs12Filename {
                            Text(verbatim: pkcs12Filename)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .accessibilityIdentifier("signing.p12Filename")
                        }
                    }
                }.accessibilityIdentifier("signing.chooseP12")
                Button {
                    selectingProfile = true; picking = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hostText("Choose provisioning profile"))
                        if let profileFilename {
                            Text(verbatim: profileFilename)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .accessibilityIdentifier("signing.profileFilename")
                        }
                    }
                }.accessibilityIdentifier("signing.chooseProfile")
                VStack(alignment: .leading, spacing: 8) {
                    Text(hostText("P12 password")).foregroundStyle(.primary)
                    SecureField(hostText("P12 password"), text: $password,
                                prompt: Text(hostText("P12 password")).foregroundStyle(.primary.opacity(0.75)))
                        .textContentType(.password)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("signing.password")
                }
            }.disabled(saving || loading)
            Section {
                Button(hostText("Save signing identity")) { save() }
                    .disabled(pkcs12 == nil || profile == nil || saving || loading)
                    .accessibilityIdentifier("signing.save")
            }
            if saved {
                Section {
                    Button(hostText("Remove signing identity"), role: .destructive) { removing = true }
                        .foregroundStyle(.red)
                        .tint(.red)
                        .disabled(saving || loading)
                        .accessibilityIdentifier("signing.remove")
                }
            }
            if saving || loading { ProgressView() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(ShellPalette.background)
        .navigationTitle(hostText("Signing identity"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving || loading || picking)
        #endif
        .interactiveDismissDisabled(saving || picking || loading)
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [UTType(filenameExtension: selectingProfile ? "mobileprovision" : "p12",
                                                   conformingTo: .data)].compactMap { $0 },
                      allowsMultipleSelection: false) { result in
            receive(result)
        }
        .confirmationDialog(hostText("Remove the signing identity from this device?"), isPresented: $removing,
                            titleVisibility: .visible) {
            Button(hostText("Remove signing identity"), role: .destructive) {
                do { try store.remove(); saved = false; savedSummary = nil; clear(); message = nil }
                catch { message = hostText("The signing identity could not be removed.") }
            }
        }
        .alert(Text(verbatim: hostText("Signing identity")), isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button(hostText("OK")) { message = nil }
            } message: { Text(message ?? "") }
        .onAppear { refreshSavedSummary() }
        .onDisappear { clear() }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
    }

    private func clear() {
        password = ""; pkcs12 = nil; profile = nil
        pkcs12Filename = nil; profileFilename = nil
    }

    private func refreshSavedSummary() {
        saved = store.hasIdentity
        savedSummary = saved ? store.identitySummary() : nil
    }

    private func receive(_ result: Result<[URL], Error>) {
        if case .failure(let error) = result {
            let error = error as NSError
            guard !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError),
                  !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
            message = hostText("Choose a valid P12 certificate or provisioning profile.")
            return
        }
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard !loading else { return }
        let isProfile = selectingProfile
        let expected = isProfile ? "mobileprovision" : "p12"
        guard url.pathExtension.lowercased() == expected else {
            message = hostText("Choose a valid P12 certificate or provisioning profile.")
            return
        }
        let limit = isProfile ? ProvisioningProfile.maxProfileBytes : 1024 * 1024
        loading = true
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                try? ShellSigningIdentityStore.readImportedFile(url, maximumBytes: limit)
            }.value
            loading = false
            if let data {
                if isProfile {
                    profile = data; profileFilename = url.lastPathComponent
                } else {
                    pkcs12 = data; pkcs12Filename = url.lastPathComponent
                }
                message = nil
            } else {
                message = hostText("Choose a valid P12 certificate or provisioning profile.")
            }
        }
    }

    private func save() {
        guard let pkcs12, let profile, !saving else { return }
        saving = true
        let enteredPassword = password
        password = ""
        let identityStore = store
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> ShellSigningIdentityStore.Failure? in
                do {
                    try identityStore.save(pkcs12: pkcs12, profile: profile, password: enteredPassword)
                    return nil
                } catch let error as ShellSigningIdentityStore.Failure { return error }
                catch { return .storage }
            }.value
            saving = false
            if let outcome {
                switch outcome {
                case .hostSignatureUnavailable: message = hostText("This app's signing certificate could not be verified.")
                case .signerMismatch: message = hostText("Choose the P12 certificate used to sign this app.")
                case .certificateNotInProfile: message = hostText("The provisioning profile does not include this P12 certificate.")
                case .expired: message = hostText("The provisioning profile is expired or invalid.")
                case .invalid: message = hostText("Check the P12 password and use a profile from this app's signing team.")
                default: message = hostText("The signing identity could not be saved. Unlock this device and try again.")
                }
            } else {
                clear(); refreshSavedSummary()
                message = hostText("Signing identity saved. Choose an imported game to re-sign.")
            }
        }
    }
}
