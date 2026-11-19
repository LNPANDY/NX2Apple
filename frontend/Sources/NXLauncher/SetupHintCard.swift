import SwiftUI
import NXCore
import NXModel

/// The hint at the top of the Builds page while the repository or a tool is missing. Observes the repository and dependency stores.
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
            HStack(spacing: 14) {
                Image(systemName: "gearshape.fill").font(.system(size: 24))
                    .foregroundStyle(.orange).frame(width: 52, height: 52)
                    .background(LauncherPalette.ink(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(loc.t("library.setupHint")).font(.manrope(14, .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(loc.t("build.setup"), action: onOpenSettings)
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .padTarget("set.build.setup", scope: "main", activate: onOpenSettings)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
        }
    }
}
