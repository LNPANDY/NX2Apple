import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXLauncher

/// The keys step's list: one row for the prod.keys file (its state, Choose or Change), a dropped file lands on it, a problem with the
/// file under it. Under the card the two ways on without keys: the Gen 2 note and Add keys later.
struct OnboardingKeysContent: View {
    let state: OnboardingState
    let lang: Lang
    @Binding var helpOpen: Bool
    let choose: () -> Void
    let receive: (URL) -> Void
    let skip: () -> Void
    @State private var targeted = false
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var file: URL? {
        if case let .found(url) = state.keys { return url }
        return state.keysFile
    }
    private var enabled: Bool { state.keys != .validating }
    private var status: OnboardingStatus {
        switch state.keys {
        case .valid: return .met
        case .invalid: return .problem
        case .searching, .validating: return .working
        case .found, .empty, .skipped: return .todo
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            DSCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    OnboardingStatusRow(title: file?.lastPathComponent ?? "prod.keys",
                                        detail: t(state.keys == .empty || state.keys == .skipped ? "onboarding.keys.drop" : state.keys.statusKey),
                                        status: status, help: file?.path ?? "") {
                        Button(t(file == nil ? "onboarding.choose" : "data.change"), action: choose)
                            .buttonStyle(DSRowButtonStyle()).disabled(!enabled)
                            .padTarget("onboarding.choose.keys", scope: "onboarding", enabled: enabled, activate: choose)
                    }
                    if case let .invalid(reason) = state.keys {
                        DSInlineWarning(reason)
                            .padding(.leading, OnboardingRowDivider.inset).padding(.trailing, DS.Space.m).padding(.bottom, DS.Space.s)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.accent, lineWidth: 1).opacity(targeted ? 1 : 0))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard enabled, let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                    DispatchQueue.main.async { receive(url) }
                }
                return true
            }
            HStack(spacing: DS.Space.xs) {
                OnboardingKeysHelp(open: $helpOpen, lang: lang, canSkip: state.canSkipKeys, skip: skip)
                Button(t("onboarding.keys.later"), action: skip)
                    .buttonStyle(DSRowButtonStyle()).disabled(!state.canSkipKeys)
                    .padTarget("onboarding.keys.later", scope: "onboarding", enabled: state.canSkipKeys, activate: skip)
            }
        }
    }
}

struct OnboardingKeysHelp: View {
    @Binding var open: Bool
    let lang: Lang
    let canSkip: Bool
    let skip: () -> Void
    @EnvironmentObject private var pad: PadFocus
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    var body: some View {
        Button { open.toggle() } label: { Label(t("onboarding.keys.gen2"), systemImage: "info.circle") }
            .buttonStyle(DSRowButtonStyle())
            .padTarget("onboarding.keys.help", scope: "onboarding") { open.toggle() }
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text(t("onboarding.keys.gen2Note")).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Button(t("onboarding.keys.skip")) { open = false; skip() }
                        .buttonStyle(DSSecondaryButtonStyle()).disabled(!canSkip)
                        .keyboardShortcut(.return, modifiers: [])
                        .padTarget("onboarding.keys.help.skip", scope: "onboarding.keysHelp", enabled: canSkip) { open = false; skip() }
                }.padding(DS.Space.l).frame(width: 340)
                    .environmentObject(pad).padScope("onboarding.keysHelp", pad)
                    .onAppear {
                        pad.scope = "onboarding.keysHelp"
                        if pad.visible { pad.show(default: "onboarding.keys.help.skip") }
                    }
                    .onExitCommand { open = false }
            }
    }
}
