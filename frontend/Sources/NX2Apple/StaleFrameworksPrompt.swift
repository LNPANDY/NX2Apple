import SwiftUI
import NXCore
import NXModel

private struct StaleFrameworksPrompt: ViewModifier {
    @ObservedObject var m: BuildStore
    @EnvironmentObject var loc: Localizer

    func body(content: Content) -> some View {
        content.alert(loc.t("stale.title"), isPresented: Binding(get: { !m.staleFrameworks.isEmpty },
                                                                set: { if !$0 { m.stopForStaleFrameworks() } })) {
            Button(loc.t("stale.go")) { m.continueWithStaleFrameworks() }
            Button(loc.t("stale.stop"), role: .cancel) { m.stopForStaleFrameworks() }
        } message: {
            Text(String(format: loc.t("stale.message"), StaleFrameworks.list(m.staleFrameworks)))
        }
    }
}

extension View {
    func staleFrameworksPrompt(_ m: BuildStore) -> some View { modifier(StaleFrameworksPrompt(m: m)) }
}
