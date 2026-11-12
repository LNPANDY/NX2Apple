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

    package init(build: BuildStore, dependencies: DependencyStore, repo: RepoStore) {
        self.build = build
        self.dependencies = dependencies
        self.repo = repo
    }

    private var buildDisabled: Bool {
        build.stopping || (!build.running && !build.canStartBuildOrQueue)
    }

    private var buttonLabel: String {
        if build.running { return loc.t(build.stopping ? "library.stopping" : "btn.stop") }
        if build.hasQueuedBuilds { return loc.t("build.start") }
        return build.done ? loc.t("btn.rebuild") : loc.t("build.startGame")
    }

    package var body: some View {
        HStack(spacing: 18) {
            statusText
            Spacer(minLength: 12)
            Button {
                build.running ? build.stop() : build.startBuildOrQueue()
            } label: {
                Label(buttonLabel,
                      systemImage: build.running ? "stop.fill" : "hammer.fill")
                    .font(.manrope(15, .semibold)).padding(.horizontal, 24).padding(.vertical, 13)
                    .foregroundStyle(build.running ? LauncherPalette.onBuilding : LauncherPalette.onCream).background(build.running ? LauncherPalette.building : LauncherPalette.cream, in: Capsule())
                    .overlay(Capsule().strokeBorder(LauncherPalette.actionBorder))
            }
            .buttonStyle(.plain)
            .disabled(buildDisabled)
            .opacity(buildDisabled ? 0.4 : 1)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 2)
        .staleFrameworksPrompt(build)
    }

    @ViewBuilder private var statusText: some View {
        if !build.doneNote.isEmpty {
            Text(build.doneNote).font(.manrope(13))
                .foregroundStyle(build.done ? LauncherPalette.ready : LauncherPalette.building).lineLimit(3)
        } else if !dependencies.checked {
            Text(loc.t("status.checkingDeps")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
        } else if !dependencies.allPresent {
            Text(loc.t("status.installFirst")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if !repo.isRepo {
            Text(loc.t("status.chooseRepo")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if build.hasQueuedBuilds {
            if build.queueNeedsDevice {
                Text(loc.t("shell.needsDevice")).font(.manrope(13)).foregroundStyle(LauncherPalette.building).lineLimit(3)
            } else {
                Text(String(format: loc.t("queue.readyStatus"), build.queuedCount))
                    .font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(2)
            }
        } else if build.gameFolderRefused {
            Text(loc.t("status.fixFolder")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
        } else if !build.inputsReady {
            Text(loc.t("status.needInputs")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
        } else if let keyProblem = build.keyProblem, !keyProblem.isEmpty {
            Text(keyProblem).font(.manrope(13)).foregroundStyle(LauncherPalette.building).lineLimit(3)
        } else {
            Text(String(format: loc.t("status.output"), build.shortPath(build.outDir.isEmpty ? build.inputFolder : build.outDir)))
                .font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1).truncationMode(.head)
        }
    }
}
