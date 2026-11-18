import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NXCore
import NXModel

/// Settings, "Tools": the repository or the release app's engine, the dependency rows and the diagnostics row.
/// Observes the repository, engine sync and dependency stores. What it needs from the build store comes as values:
/// whether a build runs. The cache row (ShellCacheRow, which observes the build store), the experimental builder's rows (ExperimentalBuilderRow, the same)
/// and the diagnostics button come as views.
package struct ToolsCard<Diagnostics: View, ShellCache: View, Builder: View>: View {
    @ObservedObject var repo: RepoStore
    @ObservedObject var engine: EngineSyncStore
    @ObservedObject var dependencies: DependencyStore
    @EnvironmentObject private var pad: PadFocus
    @State private var invalidXcode = false
    @State private var installingEngine = false
    let buildRunning: Bool
    let shellCache: ShellCache
    let builder: Builder
    let diagnostics: Diagnostics
    @EnvironmentObject var loc: Localizer

    package init(repo: RepoStore, engine: EngineSyncStore, dependencies: DependencyStore, buildRunning: Bool,
                 @ViewBuilder shellCache: () -> ShellCache, @ViewBuilder builder: () -> Builder, @ViewBuilder diagnostics: () -> Diagnostics) {
        self.repo = repo
        self.engine = engine
        self.dependencies = dependencies
        self.buildRunning = buildRunning
        self.shellCache = shellCache()
        self.builder = builder()
        self.diagnostics = diagnostics()
    }

    package var body: some View {
        CardGroup(loc.t("section.tools"), footnote: engine.usesEngineStore ? (buildRunning && engine.status.isEmpty ? loc.t("engine.waitForBuild") : engine.status)
                : (repo.status.isEmpty ? (repo.isRepo ? "" : loc.t("repo.firstHint")) : repo.status)) {
            if engine.usesEngineStore {
                engineRows
            } else {
            CardRow(loc.t("repo.title"),
                detail: repo.isRepo ? repo.shortPath(repo.path)
                    : (repo.path.isEmpty ? loc.t("repo.notFound") : String(format: loc.t("repo.notRepo"), repo.shortPath(repo.path))),
                dot: repo.isRepo ? LauncherPalette.ready : LauncherPalette.building, help: repo.path) {
                if repo.isRepo {
                    if repo.isGit {
                        if let n = repo.behind, n > 0 {
                            Button(loc.t("repo.pull")) { repo.pull() }.disabled(repo.busy || buildRunning)
                                .padTarget("set.repoPull", scope: "main", enabled: !(repo.busy || buildRunning)) { if !(repo.busy || buildRunning) { repo.pull() } }
                        }
                        SettingsUpdateAction(repo.busy ? loc.t("settings.update.working") : loc.t("repo.check"), busy: repo.busy) { repo.checkForUpdates() }.disabled(repo.busy || buildRunning)
                            .padTarget("set.repoCheck", scope: "main", enabled: !(repo.busy || buildRunning)) { if !(repo.busy || buildRunning) { repo.checkForUpdates() } }
                    } else {
                        SettingsUpdateAction(repo.busy ? loc.t("settings.update.working") : loc.t("repo.adopt"), busy: repo.busy) { repo.adoptAsGit() }.disabled(repo.busy || buildRunning)
                            .padTarget("set.repoAdopt", scope: "main", enabled: !(repo.busy || buildRunning)) { if !(repo.busy || buildRunning) { repo.adoptAsGit() } }
                    }
                }
                // Always offered, including when a repository is already configured: a saved path from
                // an earlier session (an upstream clone, a moved folder) is exactly the state a user
                // cannot fix without this button — the report had no way to leave the wrong repository.
                Button(loc.t("repo.choose")) { pickRepo() }
                    .padTarget("set.repoChoose", scope: "main", activate: pickRepo)
                if !repo.isRepo {
                    SettingsUpdateAction(repo.busy ? loc.t("settings.update.working") : loc.t("repo.download"), busy: repo.busy) { repo.clone() }.disabled(repo.busy || buildRunning)
                        .padTarget("set.repoDownload", scope: "main", enabled: !(repo.busy || buildRunning)) { if !(repo.busy || buildRunning) { repo.clone() } }
                }
            }
            if !repo.isRepo {
                // GitHub does not load everywhere: the manual route (Code → Download ZIP → unzip →
                // Choose repository) needs no git at all, and the note says which folder to pick.
                HStack(spacing: 4) {
                    Text(loc.t("repo.manualHint")).foregroundStyle(LauncherPalette.secondaryText)
                    Link("github.com/LNPANDY/NX2Apple", destination: URL(string: RepoStore.url.replacingOccurrences(of: ".git", with: ""))!)
                    Text(loc.t("repo.manualHint2")).foregroundStyle(LauncherPalette.secondaryText)
                }
                .font(.manrope(12)).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo, !repo.isGit {
                Text(loc.t(repo.autoUpdate ? "repo.noGit" : "repo.zipNoAuto")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo, !RepoLayout.missingTools(in: repo.path).isEmpty {
                Text(String(format: loc.t("repo.toolsOld"), RepoLayout.missingTools(in: repo.path).joined(separator: ", ")))
                    .font(.manrope(12)).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo {   // a ZIP copy too: its adoption at launch follows this switch
                CardDivider()
                CardRow(loc.t("repo.auto"), detail: loc.t("repo.autoNote")) {
                    Toggle(loc.t("repo.auto"), isOn: $repo.autoUpdate).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.repoAuto", scope: "main") { repo.autoUpdate.toggle() }
                }
            }
            }
        }.onChange(of: engine.available?.version) { version in
            if version == nil, pad.focused == "set.engineInstall" { pad.focused = "set.engineCheck" }
        }
        CardGroup(loc.t("settings.xcodeGroup")) {
            CardRow(loc.t("xcodeChoice.title"), detail: dependencies.xcodeApp ?? loc.t("xcodeChoice.system")) {
                if dependencies.xcodeApp != nil {
                    Button(loc.t("xcodeChoice.reset")) { dependencies.selectXcode(nil) }
                        .padTarget("set.xcodeReset", scope: "main") { dependencies.selectXcode(nil) }
                }
                Button(loc.t("xcodeChoice.choose")) { pickXcode() }
                    .padTarget("set.xcodeChoose", scope: "main", activate: pickXcode)
            }
            .disabled(buildRunning || dependencies.deps.contains(where: \.installing))
             .sheet(isPresented: $invalidXcode) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(loc.t("xcodeChoice.invalid")).font(.manrope(20, .bold)).fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button(loc.t("library.ok")) { invalidXcode = false }
                        .buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                        .padTarget("xcodemessage.cancel", scope: "xcodemessage") { invalidXcode = false } }
                }.padding(28).frame(width: 460).background(LauncherPalette.background).launcherAppearance().padScope("xcodemessage", pad)
            }
            .onChange(of: invalidXcode) { open in pad.scope = open ? "xcodemessage" : "main" }
            CardDivider()
            HStack(spacing: 8) {
                CardDisclosure(loc.t("dep.title"), detail: !dependencies.checked ? loc.t("dep.checking") : (dependencies.allPresent ? loc.t("dep.allReady") : String(format: loc.t("dep.missing"), dependencies.deps.filter { !$0.present }.count)), isOpen: dependencies.open) { dependencies.toggle() }
                    .padTarget("set.deps.expand", scope: "main", radius: 0) { dependencies.toggle() }
                SettingsUpdateAction(loc.t(dependencies.checked ? "dep.recheck" : "settings.update.checking"), busy: !dependencies.checked) { _ = dependencies.check() }
                    .disabled(!dependencies.checked)
                    .padTarget("set.deps", scope: "main", enabled: dependencies.checked) { if dependencies.checked { _ = dependencies.check() } }
            }.padding(.trailing, 18)
            if dependencies.open {
                ForEach(dependencies.deps, id: \.id) { d in
                    CardDivider()
                    VStack(alignment: .leading, spacing: 0) {
                        CardRow(loc.t(d.name), detail: repo.shortPath(dependencies.detail(of: d)), dot: d.present && !d.warning ? LauncherPalette.ready : LauncherPalette.building,
                            help: loc.t(d.hint)) {
                            if d.installing {
                                ProgressView().controlSize(.small)
                                Text(loc.t("dep.installing")).font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                            } else if !d.present && !(d.id == "xcode" && dependencies.xcodeApp != nil && d.installCmd.isEmpty) {
                                Button(d.actionLabel.isEmpty ? (d.installCmd.isEmpty ? loc.t("dep.openAppStore") : loc.t("dep.install")) : loc.t(d.actionLabel)) { _ = dependencies.install(d) }
                                    .padTarget("set.dep.install." + d.id, scope: "main") { _ = dependencies.install(d) }
                            }
                        }
                        // Why the last install failed, and what to do about it: the tool's own
                        // error line under the row, the fix (a command or a place to look) below it.
                        if !d.lastError.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(d.lastError).font(.mono(11)).foregroundStyle(LauncherPalette.building)
                                    .lineLimit(3).help(d.lastError)
                                if !d.fixHint.isEmpty {
                                    Text(loc.t(d.fixHint)).font(.manrope(11.5)).foregroundStyle(LauncherPalette.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.leading, 37).padding(.trailing, 18).padding(.bottom, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        CardGroup(loc.t("settings.storageGroup")) { shellCache }
        builder
        CardGroup(loc.t("diag.title")) {
            CardRow(loc.t("diag.title"), info: ("set.diag.help", loc.t("diag.note"))) { diagnostics }
        }
    }

    /// The release app's engine (EngineSyncStore): which one the build uses, its channel, and the automatic update.
    @ViewBuilder private var engineRows: some View {
        let idle = !(engine.busy || buildRunning)
        CardRow(loc.t("engine.title"), detail: engine.detail,
            dot: engine.selection.engineID.isEmpty ? LauncherPalette.building : LauncherPalette.ready, help: repo.path) {
            if let next = engine.available {
                SettingsUpdateAction(engine.busy && installingEngine ? engineBusyTitle : String(format: loc.t("engine.install"), next.version),
                                     busy: engine.busy && installingEngine, prominent: !engine.busy) {
                    installingEngine = true; engine.installAvailable()
                }.disabled(buildRunning || engine.busy && !installingEngine)
                    .padTarget("set.engineInstall", scope: "main", enabled: idle || engine.busy && installingEngine) {
                        if idle { installingEngine = true; engine.installAvailable() }
                    }
            }
            SettingsUpdateAction(engine.busy && !installingEngine ? engineBusyTitle : loc.t("repo.check"), busy: engine.busy && !installingEngine) {
                installingEngine = false; engine.checkForUpdate()
            }.disabled(buildRunning || engine.busy && installingEngine)
                .padTarget("set.engineCheck", scope: "main", enabled: idle || engine.busy && !installingEngine) {
                    if idle { installingEngine = false; engine.checkForUpdate() }
                }
        }.onChange(of: engine.busy) { busy in if !busy { installingEngine = false } }
        CardDivider()
        // A different channel is asked about first (the alert below): the switch can recompile every game's shaders
        // Experimental older than or equal to Stable (#1095): no switch to it, and a way back when the launcher is on it
        let choice = engine.channelChoice
        CardRow(loc.t("engine.update"), detail: choice.noteKey.map { loc.t($0) } ?? "", info: ("set.engineChannel.help", loc.t("engine.channelNote"))) {
            if choice.offersBackToStable {
                Button(loc.t("engine.backToStable")) { engine.requestChannel(.stable) }.disabled(!idle)
                    .padTarget("set.engineBack", scope: "main", enabled: idle) { if idle { engine.requestChannel(.stable) } }
            }
            LauncherDropdown(options: choice.options.map { (value: $0.rawValue, label: loc.t($0.labelKey)) },
                             selection: engine.selection.channel.rawValue) { v in
                if let channel = EngineChannel(rawValue: v) { engine.requestChannel(channel) }
            }
            .disabled(!idle)
            .padTarget("set.engineChannel", scope: "main", enabled: idle) {
                if idle { engine.requestChannel(engine.selection.channel == .stable ? .experimental : .stable) }   // refused while Experimental is not ahead
            }
        }
        .sheet(isPresented: Binding(get: { engine.confirmingChannel != nil }, set: { if !$0 { engine.cancelChannel() } })) {
            if let channel = engine.confirmingChannel {
                LauncherConfirmSheet(title: loc.t("engine.switch.title"), subtitle: "", note: engine.selection.channel.switchWarningKey(to: channel).map { loc.t($0) } ?? "",
                    cancelTitle: loc.t("engine.switch.cancel"), confirmTitle: String(format: loc.t("engine.switch.go"), loc.t(channel.labelKey)), scope: "enginechannel",
                    cancel: { engine.cancelChannel() }, confirm: { engine.confirmChannel(channel) })
            }
        }
        .onChange(of: engine.confirmingChannel) { channel in pad.scope = channel == nil ? "main" : "enginechannel" }
        CardDivider()
        CardRow(loc.t("repo.auto"), detail: loc.t("engine.autoNote")) {
            Toggle(loc.t("repo.auto"), isOn: $repo.autoUpdate).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.repoAuto", scope: "main") { repo.autoUpdate.toggle() }
        }
    }

    private var engineBusyTitle: String {
        guard let value = engine.downloadFraction, value.isFinite else { return loc.t("settings.update.working") }
        if value >= 1 { return loc.t("settings.update.preparing") }
        return String(format: loc.t("settings.update.downloading"), Int((min(max(value, 0), 1) * 100).rounded()))
    }

    private func pickXcode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = loc.t("xcodeChoice.message")
        if panel.runModal() == .OK, let url = panel.url {
            invalidXcode = !dependencies.selectXcode(url)
        }
    }

    private func pickRepo() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        d.message = loc.t("repo.pickMessage")
        if d.runModal() == .OK, let u = d.url { repo.path = u.path }
    }
}
