import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXLauncher

struct OnboardingKeysContent: View {
    let state: OnboardingState
    let lang: Lang
    let choose: () -> Void
    let receive: (URL) -> Void
    @State private var targeted = false
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var file: URL? {
        if case let .found(url) = state.keys { return url }
        return state.keysFile
    }
    private var enabled: Bool { state.keys != .validating }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if state.keys == .validating || state.keys == .searching {
                        ProgressView().controlSize(.small).tint(LauncherPalette.accent)
                    } else {
                        Image(systemName: invalid ? "key.slash.fill" : "key.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(invalid ? LauncherPalette.building : state.keys == .valid ? LauncherPalette.ready : LauncherPalette.secondaryText)
                    }
                }
                .frame(width: 52, height: 52)
                .background(LauncherPalette.ink(0.08), in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(file?.lastPathComponent ?? "prod.keys").font(.manrope(14, .semibold))
                    Text(t(state.keys == .empty || state.keys == .skipped ? "onboarding.keys.drop" : state.keys.statusKey))
                        .font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).help(file?.path ?? "")
                Button(t(file == nil ? "onboarding.choose" : "data.change"), action: choose)
                    .buttonStyle(LauncherSecondaryButtonStyle()).disabled(!enabled)
                    .padTarget("onboarding.choose.keys", scope: "onboarding", enabled: enabled, activate: choose)
            }
            .padding(18)
            .background(targeted ? LauncherPalette.selectedFillStrong : LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? LauncherPalette.accent : LauncherPalette.ink(0.08)))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard enabled, let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                    DispatchQueue.main.async { receive(url) }
                }
                return true
            }
            if case let .invalid(reason) = state.keys {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.manrope(13)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.building.opacity(0.25)))
            }
        }
    }
    private var invalid: Bool { if case .invalid = state.keys { return true }; return false }
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
            .buttonStyle(LauncherSecondaryButtonStyle())
            .padTarget("onboarding.keys.help", scope: "onboarding") { open.toggle() }
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(t("onboarding.keys.gen2Note")).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                    Button(t("onboarding.keys.skip")) { open = false; skip() }
                        .buttonStyle(LauncherSecondaryButtonStyle()).disabled(!canSkip)
                        .keyboardShortcut(.return, modifiers: [])
                        .padTarget("onboarding.keys.help.skip", scope: "onboarding.keysHelp", enabled: canSkip) { open = false; skip() }
                }.padding(20).frame(width: 340)
                    .environmentObject(pad).padScope("onboarding.keysHelp", pad)
                    .onAppear {
                        pad.scope = "onboarding.keysHelp"
                        if pad.visible { pad.show(default: "onboarding.keys.help.skip") }
                    }
                    .onExitCommand { open = false }
            }
    }
}
