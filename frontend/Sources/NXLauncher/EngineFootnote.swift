import SwiftUI
import NXCore
import NXModel

/// The engine as one quiet line on the build pages, in place of the Build engine card (#1458): "Built with nxnative · Change".
/// Change opens Settings › Tools, where the engine is chosen (EngineSwitcherCard).
package struct EngineFootnote: View {
    @ObservedObject var build: BuildStore
    let change: () -> Void
    @EnvironmentObject private var loc: Localizer
    package init(build: BuildStore, change: @escaping () -> Void) { self.build = build; self.change = change }
    package var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(String(format: loc.t("build.builtWith"), build.buildUpstream.displayName))
                .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            Text("·").font(DS.Font.callout).foregroundStyle(DS.Color.textTertiary).accessibilityHidden(true)
            Button(loc.t("engine.changeLink"), action: change)
                .buttonStyle(.plain).font(DS.Font.callout.weight(.semibold)).foregroundStyle(DS.Color.textPrimary)
                .padTarget("set.build.engine.change", scope: "main", activate: change)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
