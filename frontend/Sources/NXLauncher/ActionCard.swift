import SwiftUI
import NXCore
import NXModel

/// The page's conclusion, at the end of its column: what is still missing, and the build button.
/// Observes the build store, and the dependency and repository stores for the status text.
package struct ActionCard: View {
    @ObservedObject var build: BuildStore
    @ObservedObject var dependencies: DependencyStore
    @ObservedObject var repo: RepoStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus

    package init(build: BuildStore, dependencies: DependencyStore, repo: RepoStore) {
        self.build = build
        self.dependencies = dependencies
        self.repo = repo
    }

    private var buildDisabled: Bool {
        build.stopping || (!build.running && (build.choosesTitle ? build.failureChoice == nil || !build.canBuild : !build.canStartBuildOrQueue))
    }

    /// Build game builds the game picked in the failure's list when the folder held several (BuildFailureCard).
    private func act() {
        if build.running { build.stop() }
        else if build.choosesTitle, let choice = build.failureChoice { build.buildTitle(choice) }
        else { build.startBuildOrQueue() }
    }

    private var buttonLabel: String {
        if build.running { return loc.t(build.stopping ? "library.stopping" : "btn.stop") }
        if build.hasQueuedBuilds { return loc.t("queue.start") }
        return build.done ? loc.t("btn.rebuild") : loc.t("build.startGame")
    }

    package var body: some View {
        let primaryButton = Button(action: act) {
            Label {
                Text(buttonLabel).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            } icon: {
                Image(systemName: build.running ? "stop.fill" : "hammer.fill")
            }
            .font(DS.Font.bodyStrong).padding(.horizontal, 20).frame(height: LauncherControl.height)
            .foregroundStyle(build.running ? LauncherPalette.onBuilding : LauncherPalette.onCream)
            .background(build.running ? LauncherPalette.building : LauncherPalette.cream, in: Capsule())
            .overlay(DSPill().strokeBorder(LauncherPalette.actionBorder))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(buildDisabled)
        .opacity(buildDisabled ? 0.4 : 1)
        .keyboardShortcut(focus.scope == "main" ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .padTarget("set.build.action", scope: "main", focusColor: build.running ? LauncherPalette.onBuilding : LauncherPalette.onCream, enabled: !buildDisabled) {
            if !buildDisabled { act() }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                statusText
                Spacer(minLength: 12)
                primaryButton
            }
            VStack(alignment: .trailing, spacing: 10) {
                statusText.frame(maxWidth: .infinity, alignment: .leading)
                primaryButton
            }
        }
        .padding(.top, 2)
        .staleFrameworksPrompt(build)
    }

    @ViewBuilder private var statusText: some View {
        if !build.running && build.choosesTitle {
            // the one thing missing is the choice: the folder's files are there
            Text(loc.t(build.failureChoice == nil ? "fail.severalGames.choose" : "status.chosenGame")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !build.doneNote.isEmpty && (build.running || !build.hasQueuedBuilds) {
            Text(build.doneNote).font(DS.Font.body)
                .foregroundStyle(build.done ? LauncherPalette.ready : LauncherPalette.building).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } else if !dependencies.checked {
            Text(loc.t("status.checkingDeps")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        } else if !dependencies.allPresent {
            Text(loc.t("status.installFirst")).font(DS.Font.body).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
        } else if !repo.isRepo && !build.usesExternalUpstreamRepo {
            Text(loc.t("status.chooseRepo")).font(DS.Font.body).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
        } else if build.hasQueuedBuilds {
            if build.queueNeedsDevice {
                Text(loc.t("shell.needsDevice")).font(DS.Font.body).foregroundStyle(LauncherPalette.building).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        } else if build.gameFolderRefused {
            Text(loc.t("status.fixFolder")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        } else if !build.inputsReady {
            Text(loc.t("status.needInputs")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        } else if let keyProblem = build.keyProblem, !keyProblem.isEmpty {
            Text(keyProblem).font(DS.Font.body).foregroundStyle(LauncherPalette.building).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(String(format: loc.t("status.output"), build.shortPath(build.outDir.isEmpty ? build.inputFolder : build.outDir)))
                .font(DS.Font.body).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.head)
        }
    }
}
