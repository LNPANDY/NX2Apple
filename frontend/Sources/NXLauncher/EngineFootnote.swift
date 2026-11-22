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
            Text("·").font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).accessibilityHidden(true)
            Button(loc.t("engine.changeLink"), action: change)
                .buttonStyle(DSTextButtonStyle())
                .padTarget("set.build.engine.change", scope: "main", radius: DS.Radius.chip, activate: change)
        }
        // under the last section, its leading edge on the section headers' (CardGroup's heading is inset 4 pt)
        .padding(.leading, DS.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
