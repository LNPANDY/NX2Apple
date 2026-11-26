import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NXCore
import NXModel

/// Settings, "Tools": the repository or the release app's engine, the dependency rows and the diagnostics row.
/// Observes the repository, engine sync and dependency stores. What it needs from the build store comes as values:
/// whether a build runs. The cache row (ShellCacheRow, which observes the build store), the engine row (UpstreamBuilderRow, the same)
/// and the diagnostics button come as views, the Build engine row's nxkit (Beta) parts as a value (BuildEngineRow).
package struct ToolsCard<Diagnostics: View, ShellCache: View, Builder: View, Upstream: View>: View {
    @ObservedObject var repo: RepoStore
    @ObservedObject var engine: EngineSyncStore
    @ObservedObject var dependencies: DependencyStore
    @EnvironmentObject private var pad: PadFocus
    @State private var invalidXcode = false
    @State private var installingEngine = false
    let buildRunning: Bool
    let shellCache: ShellCache
    let builder: Builder
    /// The engine pop-up (UpstreamPicker): the Build engine row's control when more than one engine can build.
    let upstream: Upstream?
    /// What the Build engine row takes from the chosen engine when it is not nxnative (UpstreamBuilderRow.engineRow).
    let engineRow: BuildEngineRow
    let diagnostics: Diagnostics
    @EnvironmentObject var loc: Localizer

    package init(repo: RepoStore, engine: EngineSyncStore, dependencies: DependencyStore, buildRunning: Bool,
                 @ViewBuilder shellCache: () -> ShellCache, @ViewBuilder builder: () -> Builder, upstream: (() -> Upstream)?,
                 engineRow: BuildEngineRow = BuildEngineRow(), @ViewBuilder diagnostics: () -> Diagnostics) {
        self.repo = repo
        self.engine = engine
        self.dependencies = dependencies
        self.buildRunning = buildRunning
        self.shellCache = shellCache()
        self.builder = builder()
        self.upstream = upstream?()
        self.engineRow = engineRow
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
                // One action in the column: Pull when behind, else Check, Make updatable or Download. Choose repository, always
                // offered (a saved path from an earlier session is a state a user cannot leave without it), is in the "…" (#1458).
                let busy = repo.busy || buildRunning
                DSOverflowMenu(label: loc.t("repo.choose"),
                               options: [("choose", loc.t("repo.choose"))] + (repo.isGit && (repo.behind ?? 0) > 0 ? [("check", loc.t("repo.check"))] : []),
                               padID: "set.repoChoose") { choice in
                    if choice == "check" { if !busy { repo.checkForUpdates() } } else { pickRepo() }
                }
                if repo.isRepo {
                    if repo.isGit {
                        if let n = repo.behind, n > 0 {
                            Button(loc.t("repo.pull")) { repo.pull() }.disabled(busy)
                                .padTarget("set.repoPull", scope: "main", enabled: !busy) { if !busy { repo.pull() } }
                        } else {
                            SettingsUpdateAction(repo.busy ? loc.t("settings.update.working") : loc.t("repo.check"), busy: repo.busy) { repo.checkForUpdates() }.disabled(busy)
                                .padTarget("set.repoCheck", scope: "main", enabled: !busy) { if !busy { repo.checkForUpdates() } }
                        }
                    } else {
                        SettingsUpdateAction(repo.busy ? loc.t("settings.update.working") : loc.t("repo.adopt"), busy: repo.busy) { repo.adoptAsGit() }.disabled(busy)
                            .padTarget("set.repoAdopt", scope: "main", enabled: !busy) { if !busy { repo.adoptAsGit() } }
                    }
                } else {
                    SettingsUpdateAction(repo.busy ? loc.t("settings.update.working") : loc.t("repo.download"), busy: repo.busy) { repo.clone() }.disabled(busy)
                        .padTarget("set.repoDownload", scope: "main", enabled: !busy) { if !busy { repo.clone() } }
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
                .font(DS.Font.callout).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, DSRowInset.title).padding(.trailing, DS.Space.m).padding(.bottom, DS.Space.s)
            }
            if repo.isRepo, !repo.isGit {
                Text(loc.t(repo.autoUpdate ? "repo.noGit" : "repo.zipNoAuto")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DSRowInset.title).padding(.trailing, DS.Space.m).padding(.bottom, DS.Space.s)
            }
            if repo.isRepo, !RepoLayout.missingTools(in: repo.path).isEmpty {
                DSInlineWarning(String(format: loc.t("repo.toolsOld"), RepoLayout.missingTools(in: repo.path).joined(separator: ", ")))
                    .padding(.leading, DSRowInset.title).padding(.trailing, DS.Space.m).padding(.bottom, DS.Space.s)
            }
            if repo.isRepo {   // a ZIP copy too: its adoption at launch follows this switch
                CardDivider()
                CardRow(loc.t("repo.auto"), detail: loc.t("repo.autoNote")) {
                    Toggle(loc.t("repo.auto"), isOn: $repo.autoUpdate).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.repoAuto", scope: "main") { repo.autoUpdate.toggle() }
                }
            }
            }
            // a checkout: the engine pop-up has a row of its own, and so has why this Mac cannot choose nxkit (Beta)
            if !engine.usesEngineStore, upstream != nil || engineRow.message != nil {
                CardDivider()
                CardRow(loc.t("engine.title"), detail: engineRow.detail ?? (upstream == nil ? "nxnative" : ""), message: engineRow.message) {
                    if let menu = engineRow.menu { menu.view }
                    if let upstream { upstream }
                }
            }
            builder   // the build source rows belong to the build tools (#1458)
        }.onChange(of: engine.available?.version) { version in
            if version == nil, pad.focused == "set.engineInstall" { pad.focused = "set.engineCheck" }
        }
        CardGroup(loc.t("settings.xcodeGroup")) {
            CardRow(loc.t("xcodeChoice.title"), detail: dependencies.xcodeApp ?? loc.t("xcodeChoice.system")) {
                if dependencies.xcodeApp != nil {
                    DSOverflowMenu(label: loc.t("xcodeChoice.reset"), options: [("reset", loc.t("xcodeChoice.reset"))], padID: "set.xcodeReset") { _ in
                        dependencies.selectXcode(nil)
                    }
                }
                Button(loc.t("xcodeChoice.choose")) { pickXcode() }
                    .padTarget("set.xcodeChoose", scope: "main", activate: pickXcode)
            }
            .disabled(buildRunning || dependencies.deps.contains(where: \.installing))
             .sheet(isPresented: $invalidXcode) {
                DSSheet(title: loc.t("xcodeChoice.invalid")) {
                    EmptyView()
                } buttons: {
                    DSSheetPrimaryButton(loc.t("library.ok")) { invalidXcode = false }
                        .background { Button("") { invalidXcode = false }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true) }
                        .padTarget("xcodemessage.cancel", scope: "xcodemessage", focusColor: DS.Color.accentOn) { invalidXcode = false }
                }
                .padScope("xcodemessage", pad)
            }
            .onChange(of: invalidXcode) { open in pad.scope = open ? "xcodemessage" : "main" }
            CardDivider()
            // One pattern for a row that opens more rows (#1458): the whole row is the button, its chevron at the trailing edge of
            // the control column. Its action (Check again) is inside, under the rows it opens.
            Button { dependencies.toggle() } label: {
                CardRow(loc.t("dep.title"), detail: !dependencies.checked ? loc.t("dep.checking") : (dependencies.allPresent ? loc.t("dep.allReady") : String(format: loc.t("dep.missing"), dependencies.deps.filter { !$0.present }.count)),
                        dot: !dependencies.checked ? nil : (dependencies.allPresent ? DSTone.success.color : DSTone.warning.color)) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.symbolDefault)
                        .rotationEffect(.degrees(dependencies.open ? 90 : 0))
                        .frame(width: DS.Control.columnWidth, alignment: .trailing).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).dsRowHover(radius: 0).launcherHover()
            .accessibilityValue(loc.t(dependencies.open ? "onboarding.expanded" : "onboarding.collapsed"))
            .padTarget("set.deps.expand", scope: "main", radius: 0) { dependencies.toggle() }
            if dependencies.open {
                HStack(spacing: DS.Space.xs) {
                    if !dependencies.checked { DSSpinner() }
                    Button(loc.t(dependencies.checked ? "dep.recheck" : "settings.update.checking")) { _ = dependencies.check() }
                        .buttonStyle(DSTextButtonStyle()).disabled(!dependencies.checked)
                        .padTarget("set.deps", scope: "main", radius: DS.Radius.chip, enabled: dependencies.checked) { if dependencies.checked { _ = dependencies.check() } }
                }
                .padding(.leading, DSRowInset.title).padding(.bottom, DS.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(dependencies.deps, id: \.id) { d in
                    CardDivider()
                    VStack(alignment: .leading, spacing: 0) {
                        CardRow(loc.t(d.name), detail: repo.shortPath(dependencies.detail(of: d)), dot: d.present && !d.warning ? LauncherPalette.ready : LauncherPalette.building,
                            help: loc.t(d.hint)) {
                            if d.installing {
                                ProgressView().controlSize(.small)
                                Text(loc.t("dep.installing")).font(DS.Font.callout).foregroundStyle(LauncherPalette.building)
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
                            .padding(.leading, DSRowInset.title).padding(.trailing, DS.Space.m).padding(.bottom, DS.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        CardGroup(loc.t("settings.storageGroup")) { shellCache }
        CardGroup("") {   // one row says what it is, its button what it does
            CardRow(loc.t("diag.title"), detail: loc.t("diag.note")) { diagnostics }
        }
    }

    /// The release app's engine (EngineSyncStore): which one the build uses, its channel, and the automatic update.
    @ViewBuilder private var engineRows: some View {
        let idle = !(engine.busy || buildRunning)
        CardRow(loc.t("engine.title"), detail: engineRow.detail ?? (engine.busy ? engineBusyTitle : engine.detail),
            dot: engineRow.detail != nil || !engine.selection.engineID.isEmpty ? LauncherPalette.ready : LauncherPalette.building,
            help: engineRow.detail != nil ? "" : repo.path, message: engineRow.message) {
            if let upstream, let menu = engineRow.menu {
                // nxkit (Beta) chosen (#1460): its own actions in the "…", the engine pop-up beside it
                menu.view
                upstream
            } else if let upstream {
                // One row for the engine (#1458): its state in the subtitle, the engine pop-up in the column, Install and Check
                // for updates in the "…" before it.
                let install = engine.available.map { [("install", String(format: loc.t("engine.install"), $0.version))] } ?? []
                DSOverflowMenu(label: loc.t("repo.check"), options: install + [("check", loc.t("repo.check"))], padID: "set.engineCheck") { choice in
                    guard idle else { return }
                    if choice == "install" { installingEngine = true; engine.installAvailable() }
                    else { installingEngine = false; engine.checkForUpdate() }
                }
                .disabled(!idle)
                upstream
            } else if let next = engine.available {
                // one action in the column: the update. Checking again is the "…" before it (#1458)
                DSOverflowMenu(label: loc.t("repo.check"), options: [("check", loc.t("repo.check"))], padID: "set.engineCheck") { _ in
                    if idle { installingEngine = false; engine.checkForUpdate() }
                }
                .disabled(!idle)
                SettingsUpdateAction(engine.busy && installingEngine ? engineBusyTitle : String(format: loc.t("engine.install"), next.version),
                                     busy: engine.busy && installingEngine, prominent: !engine.busy) {
                    installingEngine = true; engine.installAvailable()
                }.disabled(buildRunning || engine.busy && !installingEngine)
                    .padTarget("set.engineInstall", scope: "main", enabled: idle || engine.busy && installingEngine) {
                        if idle { installingEngine = true; engine.installAvailable() }
                    }
            } else {
                SettingsUpdateAction(engine.busy && !installingEngine ? engineBusyTitle : loc.t("repo.check"), busy: engine.busy && !installingEngine) {
                    installingEngine = false; engine.checkForUpdate()
                }.disabled(buildRunning || engine.busy && installingEngine)
                    .padTarget("set.engineCheck", scope: "main", enabled: idle || engine.busy && !installingEngine) {
                        if idle { installingEngine = false; engine.checkForUpdate() }
                    }
            }
        }.onChange(of: engine.busy) { busy in if !busy { installingEngine = false } }
        CardDivider()
        // A different channel is asked about first (the alert below): the switch can recompile every game's shaders
        // Experimental older than or equal to Stable (#1095): no switch to it, and a way back when the launcher is on it
        let choice = engine.channelChoice
        CardRow(loc.t("engine.update"), detail: choice.noteKey.map { loc.t($0) } ?? "", info: ("set.engineChannel.help", loc.t("engine.channelNote"))) {
            if choice.offersBackToStable {
                DSOverflowMenu(label: loc.t("engine.backToStable"), options: [("stable", loc.t("engine.backToStable"))], padID: "set.engineBack") { _ in
                    if idle { engine.requestChannel(.stable) }
                }
                .disabled(!idle)
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

/// The Build engine row's parts from an engine other than nxnative (nxkit (Beta), #1460). Empty: the row shows nxnative's state.
package struct BuildEngineRow {
    /// The "…" before the engine pop-up with that engine's actions.
    package struct Menu {
        let label: String
        let options: [(value: String, label: String)]
        let padID: String
        let disabled: Bool
        let choose: (String) -> Void

        package init(label: String, options: [(value: String, label: String)], padID: String, disabled: Bool, choose: @escaping (String) -> Void) {
            self.label = label
            self.options = options
            self.padID = padID
            self.disabled = disabled
            self.choose = choose
        }

        @MainActor var view: some View {
            DSOverflowMenu(label: label, options: options, padID: padID) { value in if !disabled { choose(value) } }.disabled(disabled)
        }
    }

    /// The subtitle in place of nxnative's version and update state.
    let detail: String?
    /// The row's message: the engine's note or problem, or why nxkit cannot be chosen on this Mac.
    let message: DSRowMessage?
    let menu: Menu?

    package init(detail: String? = nil, message: DSRowMessage? = nil, menu: Menu? = nil) {
        self.detail = detail
        self.message = message
        self.menu = menu
    }
}

extension ToolsCard where Upstream == EmptyView {
    /// Without the engine pop-up: one engine builds, so the Build engine row's column keeps its update action.
    package init(repo: RepoStore, engine: EngineSyncStore, dependencies: DependencyStore, buildRunning: Bool,
                 @ViewBuilder shellCache: () -> ShellCache, @ViewBuilder builder: () -> Builder, engineRow: BuildEngineRow = BuildEngineRow(),
                 @ViewBuilder diagnostics: () -> Diagnostics) {
        self.init(repo: repo, engine: engine, dependencies: dependencies, buildRunning: buildRunning, shellCache: shellCache, builder: builder,
                  upstream: nil, engineRow: engineRow, diagnostics: diagnostics)
    }
}
