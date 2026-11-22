import SwiftUI
import NXCore
import NXModel

/// The notice at the top of the Builds page while the repository or a tool is missing (a LauncherNotice). Observes the repository and
/// dependency stores.
package struct SetupHintCard: View {
    @ObservedObject var repo: RepoStore
    @ObservedObject var dependencies: DependencyStore
    let usesExternalUpstream: Bool
    let onOpenSettings: () -> Void
    @EnvironmentObject var loc: Localizer

    package init(
        repo: RepoStore,
        dependencies: DependencyStore,
        usesExternalUpstream: Bool = false,
        onOpenSettings: @escaping () -> Void
    ) {
        self.repo = repo
        self.dependencies = dependencies
        self.usesExternalUpstream = usesExternalUpstream
        self.onOpenSettings = onOpenSettings
    }

    package var body: some View {
        if (!repo.isRepo && !usesExternalUpstream) || !dependencies.allPresent {
            LauncherNotice(LauncherNoticeItem(id: "build.setup", tone: .warning, symbol: "gearshape.fill", title: loc.t("library.setupHint"),
                                              action: .init(title: loc.t("build.setup"), padID: "set.build.setup", perform: onOpenSettings)))
        }
    }
}
