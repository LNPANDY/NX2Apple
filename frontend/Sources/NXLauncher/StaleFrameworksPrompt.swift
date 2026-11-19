import SwiftUI
import NXCore
import NXModel

private struct StaleFrameworksPrompt: ViewModifier {
    @ObservedObject var m: BuildStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { !m.staleFrameworks.isEmpty }, set: { if !$0 { m.stopForStaleFrameworks() } })) {
            LauncherConfirmSheet(title: loc.t("stale.title"), subtitle: "",
                note: String(format: loc.t("stale.message"), StaleFrameworks.list(m.staleFrameworks)),
                cancelTitle: loc.t("stale.stop"), confirmTitle: loc.t("stale.go"), scope: "staleframeworks",
                cancel: { m.stopForStaleFrameworks() }, confirm: { m.continueWithStaleFrameworks() }).environmentObject(focus)
        }
        .onChange(of: m.staleFrameworks.isEmpty) { empty in focus.scope = empty ? "main" : "staleframeworks" }
    }
}

extension View {
    package func staleFrameworksPrompt(_ m: BuildStore) -> some View { modifier(StaleFrameworksPrompt(m: m)) }
}
