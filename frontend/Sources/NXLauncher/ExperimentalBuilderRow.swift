import SwiftUI
import AppKit
import NXCore
import NXModel

/// Settings, "Build tools": the switch of the experimental builder (#749) and, when it is on, the nxb binary it uses with a button to choose it.
/// A view of its own because it observes the build store, which keeps the setting with the other build settings. ToolsCard takes it as a view.
package struct ExperimentalBuilderRow: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        CardRow(loc.t("builder.title"), detail: loc.t("builder.note")) {
            Toggle("", isOn: $build.experimentalBuilder).labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(build.running)
        }
        if build.experimentalBuilder {
            CardDivider()
            let nxb = build.experimentalBuilderBinary
            CardRow(loc.t("builder.program"), detail: nxb.map { RepoLayout.shortPath($0) } ?? loc.t("builder.notFound"),
                    dot: nxb == nil ? LauncherPalette.building : LauncherPalette.ready, help: nxb ?? "") {
                Button(loc.t("builder.choose")) { pick() }.disabled(build.running)
                    .padTarget("set.builderChoose", scope: "main") { if !build.running { pick() } }
            }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = loc.t("builder.pickMessage")
        if p.runModal() == .OK, let u = p.url { build.experimentalBuilderPath = u.path }
    }
}
