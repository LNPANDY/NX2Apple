import Combine
import SwiftUI
import NXCore
import NXLauncher
import NXModel

// NS Port Builder: a macOS front end that walks a user through building a playable
// IPA from their own Switch game files. Not part of the host runtime; drives the
// repository's scripts (build_ipa_from_nsp.py, romfs_image.py) as subprocesses.
//
// The four inputs are picked separately — base game, update, add-on content (DLC),
// prod.keys — because they are not always in one folder. When they are (the common
// case) the folder is passed straight to the script; otherwise a staging folder of
// symlinks is built and the script's --work-dir keeps the real build folder next to
// the base game.

// MARK: - Pieces

extension StepState {
    var color: Color {
        switch self {
        case .pending: return .gray
        case .running: return .yellow
        case .done: return .green
        case .failed: return .red
        }
    }
}

// MARK: - View

struct BuilderView: View {
    @ObservedObject var m: BuildStore
    @ObservedObject var updates: AppUpdateStore   // the app's self-update (Settings, "NX2Apple" section)
    @ObservedObject var repo: RepoStore   // the repository (Settings, "Tools" section, and the setup hint)
    @ObservedObject var engine: EngineSyncStore   // the engine (Settings, "Tools" section)
    @ObservedObject var dependencies: DependencyStore   // the tools (Settings, "Tools" section, and the setup hint and status)
    @ObservedObject var devices: DeviceStore   // the install target (the Builds page) and the copy card
    var diagnostics: (LibraryGame?, @escaping (String) -> Void) -> Void = { _, _ in }   // the report of Copy diagnostics (LauncherStores)
    @EnvironmentObject var loc: Localizer
    @ObservedObject var library: GameLibrary
    var settings = false
    var onViewGame: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onChooseLibraryFolder: () -> Void = {}
    var onOpenControls: () -> Void = {}
    var onOpenControllers: () -> Void = {}   // the Controllers sheet (the console mode's list, with the player-mode setting)
    var onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    var controlChanges = 0
    var padMerge: Binding<Bool> = .constant(false)   // "All controllers are player 1" (ControlLayout.padMerge)
    @AppStorage(ConsolePrompt.defaultsKey) private var consolePromptOn = true   // ConsoleCoordinator.swift
    @AppStorage(BuildNotice.defaultsKey) private var notifyBuilds = true   // BuildNotifications.swift
    @AppStorage(ReturnAfterPlay.defaultsKey) private var returnAfterPlay = true   // ReturnAfterPlay.swift
    @State private var extrasOpen = false
    @State private var logOpen = false
    @State private var keyCheck: KeyCheck.Outcome?   // prod.keys against the chosen files (KeyCheck.swift)
    @EnvironmentObject private var padFocus: PadFocus

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                if settings { settingsPage } else { buildPage }
            }
            .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 48)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: padFocus.focused) { id in   // a controller's focus on this page scrolls into view
            if let id, id.hasPrefix("set.") { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
        }
        .modifier(GameFilesDrop(enabled: !settings && !m.running, label: loc.t("drop.hint")) { m.take(dropped: $0) })   // DropFiles.swift
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    // ---- shared pieces: the library's and the launch options' look ----

    private func pageHeading(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.manrope(44, .heavy)).tracking(-1.3)
            Text(note).font(.manrope(15)).foregroundStyle(.secondary)
        }
    }

    /// A titled group: a small tracked label over one card of rows.
    private func group<Content: View>(_ label: String, footnote: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0, content: content)
                .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
            if !footnote.isEmpty {
                Text(footnote).font(.manrope(12)).foregroundStyle(.secondary).padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One line of a card: a status dot (its place kept when there is none, so every title starts on one line),
    /// the title (with a disclosure chevron beside it when `open` is given), a secondary detail, and its controls.
    /// Its buttons and dropdowns are all LauncherControl.width wide, so they line up in one column across the cards.
    private func row<Trailing: View>(_ title: String, detail: String = "", detail2: String = "", dot: Color? = nil, help: String = "", open: Bool? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Circle().fill(dot ?? .clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                    if let open {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                if !detail.isEmpty {
                    // A path is technical text: the system's monospaced face, on one line, cut in the middle when
                    // too long. Everything else is prose in Manrope and wraps, so no word is ever cut.
                    if detail.hasPrefix("/") || detail.hasPrefix("~") {
                        Text(detail).font(.mono(12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(help.isEmpty ? detail : help)
                    } else {
                        Text(detail).font(.manrope(12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).help(help.isEmpty ? detail : help)
                    }
                }
                if !detail2.isEmpty {
                    Text(detail2).font(.mono(12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(detail2)
                }
            }
            Spacer(minLength: 12)
            trailing().launcherRowControls()
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    private var divider: some View { Divider().opacity(0.25).padding(.leading, 18) }

    /// A row that opens the rows under it.
    private func disclosure(_ title: String, detail: String = "", isOpen: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.18)) { toggle() } }) {
            row(title, detail: detail, open: isOpen) { EmptyView() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // ---- Build game ----

    @ViewBuilder private var buildPage: some View {
        pageHeading(loc.t("build.heading"), note: loc.t("build.intro"))
        if !repo.isRepo || !dependencies.allPresent {
            group(loc.t("section.setup")) {
                row(loc.t("library.setupHint"), dot: LauncherPalette.building) {
                    Button(loc.t("build.setup"), action: onOpenSettings)
                }
            }
        }
        files.disabled(m.running)
        target
        if m.target != BuildTarget.mac { install.disabled(m.running) }
        logPanel
        action
        ShellCopyCard(devices: devices)
        BuildFailureCard(m: m)
        outcome
        progress
    }

    /// Where an iPhone build goes: exported as an IPA (as before), or signed and installed on a paired device.
    private var install: some View {
        let devices = devices
        let options = [(value: "", label: loc.t("dev.none"))] + devices.devices.map { d in
            (value: d.id, label: d.name + (d.reachable ? "" : " (" + loc.t("dev.notConnected") + ")"))
        }
        let teams = devices.teams.map { (value: $0.id, label: $0.label(personalTeam: loc.t("dev.personalTeam"))) }
        let needsCertificate = devices.teams.first { $0.id == devices.signingTeam }.map { !$0.hasCertificate } ?? false
        return group(loc.t("dev.section"), footnote: devices.installDevice.isEmpty ? "" : (needsCertificate ? loc.t("dev.teamNoCert") + " " : "") + loc.t("dev.note")) {
            row(loc.t("dev.target"), detail: devices.checked && devices.devices.isEmpty ? loc.t("dev.noDevices") : "") {
                if !devices.checked { ProgressView().controlSize(.small) }
                Button(loc.t("dev.refresh")) { _ = devices.refresh() }.buttonStyle(.plain).font(.manrope(13)).foregroundStyle(.secondary)
                LauncherDropdown(options: options, selection: devices.installDevice, label: loc.t("dev.target")) { devices.installDevice = $0 }
            }
            if !devices.installDevice.isEmpty {
                divider
                if teams.isEmpty {
                    row(loc.t("dev.team"), detail: loc.t("dev.noTeam"), dot: LauncherPalette.building) { EmptyView() }
                } else {
                    row(loc.t("dev.team")) {
                        LauncherDropdown(options: teams, selection: devices.signingTeam, label: loc.t("dev.team")) { devices.signingTeam = $0 }
                    }
                }
            }
        }
        .onAppear { if !devices.checked { _ = devices.refresh() } }
    }

    private var files: some View {
        // The report's own mistake, and a reasonable one: the output folder silently decides where
        // the build cache lives, so changing it threw away a finished build. Say it under Save to, all the time.
        group(loc.t("section.files"), footnote: loc.t("msg.workdirHint")) {
            Button(action: pickFolder) {
                row(loc.t(m.gameDir.isEmpty ? "build.folderCTA" : "build.folderSelected"),
                    detail: m.gameDir.isEmpty ? loc.t("build.folderNote") : m.shortPath(m.gameDir), help: m.gameDir) {
                    Text(loc.t(m.gameDir.isEmpty ? "data.choose" : "data.change"))
                        .font(.manrope(13, .semibold)).foregroundStyle(.black)
                        .launcherRowControlFrame()
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(m.slots.filter { !$0.optional }, id: \.id) { s in
                divider; slotRow(s)
                if s.id == "keys", let keyCheck { KeyCheckLine(outcome: keyCheck, t: loc.t) }
            }
            divider
            disclosure(loc.t("build.options"), isOpen: extrasOpen) { extrasOpen.toggle() }
            if extrasOpen {
                ForEach(m.slots.filter(\.optional), id: \.id) { s in divider; slotRow(s) }
            }
            divider
            row(loc.t("build.saveTo"), detail: m.outDir.isEmpty ? loc.t("build.saveDefault") : m.shortPath(m.outDir), help: m.outDir) {
                Button(loc.t("data.change")) { m.chooseBuildFolder() }
            }
        }
        .task(id: KeyCheck.Inputs(keys: m.keysPath, files: [m.basePath, m.updatePath] + m.dlcPaths)) {
            keyCheck = await KeyCheck.runDetached(KeyCheck.Inputs(keys: m.keysPath, files: [m.basePath, m.updatePath] + m.dlcPaths))
        }
    }

    private func slotRow(_ s: Slot) -> some View {
        // An empty prod.keys row says where the file comes from.
        row(loc.t(s.title), detail: s.id == "keys" && s.paths.isEmpty ? loc.t("build.keyHint") : s.summary(loc.t), dot: s.ok ? LauncherPalette.ready : LauncherPalette.unbuilt,
            help: s.paths.joined(separator: "\n")) {
            if !s.paths.isEmpty {
                Button(loc.t("data.clear")) { m.clear(s.id) }.buttonStyle(.plain)
                    .font(.manrope(13)).foregroundStyle(.secondary)
            }
            Button(s.paths.isEmpty ? loc.t("data.choose") : loc.t("data.change")) { m.pickFiles(kind: s.kind) }
        }
    }

    private func pickFolder() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        if d.runModal() == .OK, let u = d.url { m.scan(folder: u.path) }
    }

    private var target: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("section.target")).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            HStack(spacing: 14) {
                targetCard(BuildTarget.mac, symbol: "desktopcomputer", title: "build.mac", note: "build.macNote")
                targetCard(BuildTarget.ios, symbol: "iphone", title: "build.ios", note: "build.iosNote")
            }
            // A Mac app runs on this Mac's GPU, which always decodes BC textures: the switch is the iPhone's only.
            if m.target != BuildTarget.mac {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loc.t("opt.bc")).font(.manrope(14))
                            Text(loc.t("opt.bc.note")).font(.manrope(12.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $m.bcOnCPU).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(m.running)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
                .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
                .padding(.top, 4)
            }
        }
    }

    private func targetCard(_ value: String, symbol: String, title: String, note: String) -> some View {
        let selected = m.target == value
        return Button { m.target = value } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: symbol).font(.system(size: 26, weight: .light))
                        .foregroundStyle(selected ? LauncherPalette.cream : .secondary)
                    Spacer()
                    Circle().strokeBorder(selected ? LauncherPalette.cream : Color.white.opacity(0.25), lineWidth: selected ? 5 : 1.5)
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(title)).font(.manrope(16, .semibold))
                    Text(loc.t(note)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? LauncherPalette.cream.opacity(0.05) : LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LauncherPalette.cream.opacity(0.7) : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(m.running)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var outcome: some View {
        if m.done && m.target == BuildTarget.mac {
            group(loc.t("section.done")) {
                row(loc.t("library.ready"), detail: m.shortPath(m.macAppPath), dot: LauncherPalette.ready, help: m.macAppPath) {
                    Button(loc.t("install.reveal")) { reveal(m.macAppPath) }
                    Button(loc.t("build.showLibrary"), action: onViewGame)
                }
            }
        }
        if m.done && !m.installedOn.isEmpty {
            group(String(format: loc.t("dev.installed"), devices.deviceName(m.installedOn))) {
                row(loc.t("dev.installedNote"), dot: LauncherPalette.ready) {
                    Button(String(format: loc.t("dev.open"), devices.deviceName(m.installedOn))) {
                        m.openOnDevice(udid: m.installedOn, app: m.installedAppPath) { error in if let error { m.doneNote = error } }
                    }
                }
                // The game files were copied (or, after a skipped transfer, await a manual copy — a
                // fast external drive handed to the device is quicker than USB): show where they are.
                if !m.archivePath.isEmpty {
                    divider
                    row(loc.t("dev.gameData"), detail: m.shortPath(m.archivePath), dot: LauncherPalette.ready, help: m.archivePath) {
                        Button(loc.t("install.reveal")) { reveal(m.archivePath) }
                    }
                }
            }
        }
    }

    /// The script's own stages once a build has run, and its log behind a disclosure.
    @ViewBuilder private var progress: some View {
        if m.running || !m.stages.isEmpty {
            group(loc.t("section.progress")) {
                ForEach(Array(m.stages.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { divider }
                    HStack(spacing: 12) {
                        if s.state == .running { ProgressView().controlSize(.small).frame(width: 14) }
                        else { Circle().fill(s.state.color).frame(width: 7, height: 7).frame(width: 14) }
                        Text(s.name).font(.manrope(14)).lineLimit(1)
                        Spacer(minLength: 12)
                        if s.state == .running {
                            TimelineView(.periodic(from: Date(), by: 1)) { context in
                                Text([s.detail, s.clock(at: context.date, left: loc.t("prog.eta"))].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            }
                        } else if !s.detail.isEmpty { Text(s.detail).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1) }
                        if s.state == .running {
                            LauncherProgressBar(value: s.percent.map { $0 / 100 }, height: 6).frame(width: 180)
                            Text(s.percent.map { "\(Int($0))%" } ?? "").font(.manrope(13, .semibold)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                if m.stages.isEmpty && m.running {
                    row(loc.t("library.preparing")) { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    /// The build log, right under the Mac / iPhone choice and folded away until it is asked for.
    /// It used to sit at the bottom of the progress card, which is where a failed build's message
    /// pointed ("see the log below") while the log itself was out of view on a short window (#52).
    @ViewBuilder private var logPanel: some View {
        group(loc.t("section.log")) {
            if devices.shellCopy != nil || devices.shellWaiting {
                // The log below is the build's own output; the data transfer is driven by the app, so
                // its questions and errors (a locked device, a failed listing) answer here, not in it.
                Text(loc.t("log.transferNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.top, 2)
            }
            disclosure(loc.t("build.log"), isOpen: logOpen) { logOpen.toggle() }
            if logOpen { logView.padding(.horizontal, 14).padding(.bottom, 14) }
        }
        .onReceive(BuildNotifier.shared.$showLog) { show in   // a clicked notification of a failed build
            if show { logOpen = true; DispatchQueue.main.async { BuildNotifier.shared.showLog = false } }
        }
    }

    private var logView: some View {
        BuildLogView(log: m.log,placeholder: loc.t("log.placeholder"))
    }

    /// The page's conclusion, at the end of its column: what is still missing, and the button.
    private var action: some View {
        HStack(spacing: 18) {
            statusText
            Spacer(minLength: 12)
            Button {
                m.running ? m.stop() : m.startBuild()
            } label: {
                Label(m.running ? loc.t(m.stopping ? "library.stopping" : "btn.stop") : (m.done ? loc.t("btn.rebuild") : loc.t("build.startGame")),
                      systemImage: m.running ? "stop.fill" : "hammer.fill")
                    .font(.manrope(15, .semibold)).padding(.horizontal, 24).padding(.vertical, 13)
                    .foregroundStyle(.black).background(m.running ? LauncherPalette.building : LauncherPalette.cream, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(m.stopping || (!m.running && !m.canBuild))
            .opacity(m.stopping || (!m.running && !m.canBuild) ? 0.4 : 1)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 2)
        .staleFrameworksPrompt(m)
    }

    @ViewBuilder private var statusText: some View {
        if !m.doneNote.isEmpty {
            Text(m.doneNote).font(.manrope(13))
                .foregroundStyle(m.done ? LauncherPalette.ready : LauncherPalette.building).lineLimit(2)
        } else if !dependencies.checked {
            Text(loc.t("status.checkingDeps")).font(.manrope(13)).foregroundStyle(.secondary)
        } else if !dependencies.allPresent {
            Text(loc.t("status.installFirst")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if !repo.isRepo {
            Text(loc.t("status.chooseRepo")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if !m.slot("base").ok || !m.slot("keys").ok {
            Text(loc.t("status.needInputs")).font(.manrope(13)).foregroundStyle(.secondary)
        } else {
            Text(String(format: loc.t("status.output"), m.shortPath(m.outDir.isEmpty ? (m.basePath as NSString).deletingLastPathComponent : m.outDir)))
                .font(.manrope(13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
    }

    // ---- Settings ----

    @ViewBuilder private var settingsPage: some View {
        pageHeading(loc.t("settings.heading"), note: loc.t("settings.note"))
        settingsCards
    }

    @ViewBuilder private var settingsCards: some View {
        group(loc.t("section.library"), footnote: loc.t("library.folderHint")) {
            row(loc.t("library.folderTitle"), detail: library.folder.isEmpty ? loc.t("library.folderUnset") : m.shortPath(library.folder),
                dot: library.folder.isEmpty ? LauncherPalette.unbuilt : LauncherPalette.ready, help: library.folder) {
                if library.scanning { ProgressView().controlSize(.small) }
                if !library.folder.isEmpty {
                    Button(loc.t("library.rescan")) { library.discover() }.disabled(library.scanning)
                        .padTarget("set.rescan", scope: "main") { if !library.scanning { library.discover() } }
                }
                Button(loc.t("library.chooseFolder"), action: onChooseLibraryFolder)
                    .padTarget("set.folder", scope: "main") { onChooseLibraryFolder() }
            }
        }
        group(loc.t("section.controls"), footnote: loc.t("controls.settingsHint")) {
            row(loc.t("controls.row"), detail: controlChanges == 0 ? loc.t("controls.defaultLayout") : String(format: loc.t("controls.changes"), controlChanges)) {
                Button(loc.t("controls.customize"), action: onOpenControls)
                    .padTarget("set.controls", scope: "main") { onOpenControls() }
            }
            divider
            row(loc.t("console.mergeAll"), detail: loc.t("console.mergeNote")) {
                Toggle("", isOn: padMerge).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.padMerge", scope: "main") { padMerge.wrappedValue.toggle() }
            }
            divider
            row(loc.t("console.controllers"), detail: loc.t("console.controllersRowNote")) {
                Button(loc.t("console.controllersOpen"), action: onOpenControllers)
                    .padTarget("set.controllers", scope: "main") { onOpenControllers() }
            }
            divider
            row(loc.t("console.promptSetting"), detail: loc.t("console.promptSettingNote")) {
                Toggle("", isOn: $consolePromptOn).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.consolePrompt", scope: "main") { consolePromptOn.toggle() }
            }
        }
        tools
        group(loc.t("section.app"), footnote: updates.status) {
            // The interface language: the device default unless someone picks one here. Stored as
            // "" (follow), "zh", "en", "sv", "de" or "fr" so a later system-language change still applies.
            row(loc.t("settings.language"),
                detail: Lang.saved.map { loc.t("settings.language.\($0.rawValue)") }
                    ?? loc.t("settings.language.system"), dot: LauncherPalette.ready, help: "") {
                // The launcher's own list, drawn like the buttons beside it and as wide as they are.
                // The language names are in their own language (see "settings.language.*"), only "system" follows the UI.
                LauncherDropdown(options: Self.languageCodes.map { (value: $0, label: loc.t("settings.language." + ($0.isEmpty ? "system" : $0))) },
                                 selection: Lang.saved.map { $0.rawValue } ?? "", label: loc.t("settings.language"),
                                 style: .button) { v in
                    loc.choose(v)
                }
                .padTarget("set.language", scope: "main", activate: { cycleLanguage(1) }, adjust: { cycleLanguage($0) })
            }
            divider
            // Build notifications (BuildNotifications.swift): none without an app bundle, e.g. under swift run
            row(loc.t("settings.notify"), detail: loc.t(BuildNotice.hasBundleID ? "settings.notifyNote" : "settings.notifyUnbundled")) {
                Toggle("", isOn: $notifyBuilds).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(!BuildNotice.hasBundleID)
                    .padTarget("set.notify", scope: "main") { notifyBuilds.toggle() }
            }
            divider
            if let onRunSetup {
                row(loc.t("settings.setup"), detail: loc.t("settings.setupNote")) {
                    Button(loc.t("settings.setupBtn"), action: onRunSetup)
                        .padTarget("set.setup", scope: "main") { onRunSetup() }
                }
                divider
            }
            // The launcher back in front when a game it started quits (ReturnAfterPlay.swift)
            row(loc.t("settings.returnAfterPlay"), detail: loc.t("settings.returnAfterPlayNote")) {
                Toggle("", isOn: $returnAfterPlay).toggleStyle(LauncherSwitchStyle()).labelsHidden()
                    .padTarget("set.returnAfterPlay", scope: "main") { returnAfterPlay.toggle() }
            }
            divider
            row("NX2Apple", detail: String(format: loc.t("app.version"), updates.version),
                dot: updates.staged != nil ? LauncherPalette.ready : nil) {
                if updates.busy { ProgressView().controlSize(.small) }
                if updates.staged != nil {
                    // Downloaded and verified: it goes in when the app quits; this restarts into it now (not during a build)
                    Button(loc.t("app.restartNow")) { updates.restartNow() }.disabled(m.running)
                        .padTarget("set.appRestart", scope: "main") { if !m.running { updates.restartNow() } }
                } else if let u = updates.update, updates.installability == .ok {
                    Button(String(format: loc.t("app.updateBtn"), u.tag)) { updates.performUpdate() }.disabled(updates.busy || m.running)
                        .padTarget("set.appUpdate", scope: "main") { if !(updates.busy || m.running) { updates.performUpdate() } }
                } else {
                    Button(loc.t("repo.check")) { updates.checkForUpdate() }.disabled(updates.busy)
                        .padTarget("set.appCheck", scope: "main") { if !updates.busy { updates.checkForUpdate() } }
                }
            }
            divider
            if updates.installability == .ok {
                // The uninstaller (Uninstall.swift): state folders and the launcher's own checkout go; the
                // games folder and prod.keys stay; the app itself goes to the Trash.
                row(loc.t("uninstall.title"), detail: loc.t("uninstall.note")) {
                    Button(loc.t("uninstall.button")) { updates.uninstallPlan = uninstallPlan() }
                    .disabled(m.running)
                    .padTarget("set.uninstall", scope: "main") { if !m.running { updates.uninstallPlan = uninstallPlan() } }
                }
                divider
            }
            // A launcher built from the repository never replaces itself (AppUpdate.installability): the switch says so and stays off
            row(loc.t("app.auto"), detail: loc.t(updates.installability == .ok ? "app.autoNote" : updates.installability == .developer ? "app.autoDev" : "app.autoReadOnly")) {
                Toggle("", isOn: Binding(get: { updates.automatic && updates.installability == .ok }, set: { updates.automatic = $0 }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(updates.installability != .ok)
                    .padTarget("set.appAuto", scope: "main") { if updates.installability == .ok { updates.automatic.toggle() } }
            }
        }
    }

    /// The interface language one step on (a controller's left / right on the language list).
    /// The language picker's choices in order, "" being the system's. A new language is one more code here and its
    /// "settings.language.<code>" entry, which is its own name (Svenska, Deutsch) in every language.
    static let languageCodes = ["", "zh", "en", "sv", "de", "fr"]

    private func cycleLanguage(_ by: Int) {
        let values = Self.languageCodes
        let at = values.firstIndex(of: Lang.saved.map { $0.rawValue } ?? "") ?? 0
        let v = values[(at + by + values.count) % values.count]
        loc.choose(v)
    }

    private func uninstallPlan() -> Uninstall.Plan {
        Uninstall.plan(home: NSHomeDirectory(), gamesFolder: library.folder, outputFolder: m.outDir,
                       checkouts: [repo.path], defaultsDomain: Bundle.main.bundleIdentifier)
    }

    private var tools: some View {
        group(loc.t("section.tools"), footnote: engine.usesEngineStore ? engine.status
                : (repo.status.isEmpty ? (repo.isRepo ? "" : loc.t("repo.firstHint")) : repo.status)) {
            if engine.usesEngineStore {
                engineRows
            } else {
            row(loc.t("repo.title"),
                detail: repo.isRepo ? m.shortPath(repo.path)
                    : (repo.path.isEmpty ? loc.t("repo.notFound") : String(format: loc.t("repo.notRepo"), m.shortPath(repo.path))),
                dot: repo.isRepo ? LauncherPalette.ready : LauncherPalette.building, help: repo.path) {
                if repo.busy { ProgressView().controlSize(.small) }
                if repo.isRepo {
                    if repo.isGit {
                        if let n = repo.behind, n > 0 {
                            Button(loc.t("repo.pull")) { repo.pull() }.disabled(repo.busy || m.running)
                                .padTarget("set.repoPull", scope: "main") { if !(repo.busy || m.running) { repo.pull() } }
                        }
                        Button(loc.t("repo.check")) { repo.checkForUpdates() }.disabled(repo.busy || m.running)
                            .padTarget("set.repoCheck", scope: "main") { if !(repo.busy || m.running) { repo.checkForUpdates() } }
                    } else {
                        Button(loc.t("repo.adopt")) { repo.adoptAsGit() }.disabled(repo.busy || m.running)
                            .padTarget("set.repoAdopt", scope: "main") { if !(repo.busy || m.running) { repo.adoptAsGit() } }
                    }
                }
                // Always offered, including when a repository is already configured: a saved path from
                // an earlier session (an upstream clone, a moved folder) is exactly the state a user
                // cannot fix without this button — the report had no way to leave the wrong repository.
                Button(loc.t("repo.choose")) { pickRepo() }
                if !repo.isRepo {
                    Button(loc.t("repo.download")) { repo.clone() }.disabled(repo.busy || m.running)
                }
            }
            if !repo.isRepo {
                // GitHub does not load everywhere: the manual route (Code → Download ZIP → unzip →
                // Choose repository) needs no git at all, and the note says which folder to pick.
                HStack(spacing: 4) {
                    Text(loc.t("repo.manualHint")).foregroundStyle(.secondary)
                    Link("github.com/LNPANDY/NX2Apple", destination: URL(string: RepoStore.url.replacingOccurrences(of: ".git", with: ""))!)
                    Text(loc.t("repo.manualHint2")).foregroundStyle(.secondary)
                }
                .font(.manrope(12)).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo, !repo.isGit {
                Text(loc.t(repo.autoUpdate ? "repo.noGit" : "repo.zipNoAuto")).font(.manrope(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo, !RepoLayout.missingTools(in: repo.path).isEmpty {
                Text(String(format: loc.t("repo.toolsOld"), RepoLayout.missingTools(in: repo.path).joined(separator: ", ")))
                    .font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo {   // a ZIP copy too: its adoption at launch follows this switch
                divider
                row(loc.t("repo.auto"), detail: loc.t("repo.autoNote")) {
                    Toggle("", isOn: $repo.autoUpdate).labelsHidden().toggleStyle(LauncherSwitchStyle())
                }
            }
            }
            divider
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { dependencies.toggle() } }) {
                row(loc.t("dep.title"),
                    detail: !dependencies.checked ? loc.t("dep.checking")
                        : (dependencies.allPresent ? loc.t("dep.allReady") : String(format: loc.t("dep.missing"), dependencies.deps.filter { !$0.present }.count)),
                    dot: !dependencies.checked ? LauncherPalette.unbuilt : (dependencies.allPresent ? LauncherPalette.ready : LauncherPalette.building),
                    open: dependencies.open) {
                    if !dependencies.checked { ProgressView().controlSize(.small) }
                    Button(loc.t("dep.recheck")) { _ = dependencies.check() }
                        .padTarget("set.deps", scope: "main") { _ = dependencies.check() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if dependencies.open {
                ForEach(dependencies.deps, id: \.id) { d in
                    divider
                    VStack(alignment: .leading, spacing: 0) {
                        row(loc.t(d.name), detail: m.shortPath(dependencies.detail(of: d)), dot: d.present && !d.warning ? LauncherPalette.ready : LauncherPalette.building,
                            help: loc.t(d.hint)) {
                            if d.installing {
                                ProgressView().controlSize(.small)
                                Text(loc.t("dep.installing")).font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                            } else if !d.present {
                                Button(d.actionLabel.isEmpty ? (d.installCmd.isEmpty ? loc.t("dep.openAppStore") : loc.t("dep.install")) : loc.t(d.actionLabel)) { _ = dependencies.install(d) }
                            }
                        }
                        // Why the last install failed, and what to do about it: the tool's own
                        // error line under the row, the fix (a command or a place to look) below it.
                        if !d.lastError.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(d.lastError).font(.mono(11)).foregroundStyle(LauncherPalette.building)
                                    .lineLimit(3).help(d.lastError)
                                if !d.fixHint.isEmpty {
                                    Text(loc.t(d.fixHint)).font(.manrope(11.5)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.leading, 37).padding(.trailing, 18).padding(.bottom, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            divider
            row(loc.t("diag.title"), detail: loc.t("diag.note")) { DiagnosticsButton(report: diagnostics, game: library.selected) }
        }
    }

    /// The release app's engine (EngineSyncStore): which one the build uses, its channel, and the automatic update.
    @ViewBuilder private var engineRows: some View {
        let idle = !(engine.busy || m.running)
        row(loc.t("engine.title"), detail: engine.detail,
            dot: engine.selection.engineID.isEmpty ? LauncherPalette.building : LauncherPalette.ready, help: repo.path) {
            if engine.busy { ProgressView().controlSize(.small) }
            if let next = engine.available {
                Button(String(format: loc.t("engine.install"), next.version)) { engine.installAvailable() }.disabled(!idle)
                    .padTarget("set.engineInstall", scope: "main") { if idle { engine.installAvailable() } }
            }
            Button(loc.t("repo.check")) { engine.checkForUpdate() }.disabled(!idle)
                .padTarget("set.engineCheck", scope: "main") { if idle { engine.checkForUpdate() } }
        }
        divider
        // A different channel is asked about first (the alert below): the switch can recompile every game's shaders
        row(loc.t("engine.update"), detail: loc.t("engine.channelNote"), dot: LauncherPalette.ready) {
            LauncherDropdown(options: EngineChannel.allCases.map { (value: $0.rawValue, label: loc.t($0.labelKey)) },
                             selection: engine.selection.channel.rawValue) { v in
                if let channel = EngineChannel(rawValue: v) { engine.requestChannel(channel) }
            }
            .disabled(!idle)
            .padTarget("set.engineChannel", scope: "main") {
                if idle { engine.requestChannel(engine.selection.channel == .stable ? .experimental : .stable) }
            }
        }
        .alert(loc.t("engine.switch.title"), isPresented: Binding(get: { engine.confirmingChannel != nil },
                                                               set: { if !$0 { engine.cancelChannel() } })) {
            if let channel = engine.confirmingChannel {
                Button(String(format: loc.t("engine.switch.go"), loc.t(channel.labelKey))) { engine.confirmChannel(channel) }
            }
            Button(loc.t("engine.switch.cancel"), role: .cancel) { engine.cancelChannel() }
        } message: {
            Text(engine.confirmingChannel.flatMap { engine.selection.channel.switchWarningKey(to: $0) }.map { loc.t($0) } ?? "")
        }
        divider
        row(loc.t("shellCache.row"), detail: loc.t("shellCache.note"), detail2: m.shellCachePath) {
            Button(loc.t("shellCache.open")) { m.revealFolder(URL(fileURLWithPath: m.shellCachePath)) }
                .buttonStyle(LauncherSecondaryButtonStyle())
        }
        divider
        row(loc.t("repo.auto"), detail: loc.t("engine.autoNote")) {
            Toggle("", isOn: $repo.autoUpdate).labelsHidden().toggleStyle(LauncherSwitchStyle())
        }
    }

    private func pickRepo() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        d.message = loc.t("repo.pickMessage")
        if d.runModal() == .OK, let u = d.url { repo.path = u.path }
    }
}
