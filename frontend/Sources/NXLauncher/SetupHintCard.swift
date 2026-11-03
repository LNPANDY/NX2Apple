import SwiftUI
import NXCore
import NXModel

/// The hint at the top of the Builds page while the repository or a tool is missing. Observes the repository and dependency stores.
package struct SetupHintCard: View {
    @ObservedObject var repo: RepoStore
    @ObservedObject var dependencies: DependencyStore
    let onOpenSettings: () -> Void
    @EnvironmentObject var loc: Localizer

    package init(repo: RepoStore, dependencies: DependencyStore, onOpenSettings: @escaping () -> Void) {
        self.repo = repo
        self.dependencies = dependencies
        self.onOpenSettings = onOpenSettings
    }

    package var body: some View {
        if !repo.isRepo || !dependencies.allPresent {
            CardGroup(loc.t("section.setup")) {
                CardRow(loc.t("library.setupHint"), dot: LauncherPalette.building) {
                    Button(loc.t("build.setup"), action: onOpenSettings)
                }
            }
        }
    }
}
