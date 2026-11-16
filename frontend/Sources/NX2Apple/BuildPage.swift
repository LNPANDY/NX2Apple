import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// Presentation steps over the release stores. Queue, export and recovery keep their existing owners.
struct BuildPage: View {
    var library: GameLibrary? = nil
    var artworkStore: ArtworkStore = .shared
    @Binding var step: Int
    @ObservedObject var build: BuildStore
    let running: Bool
    @ObservedObject var repo: RepoStore
    @ObservedObject var dependencies: DependencyStore
    let devices: DeviceStore
    @ObservedObject var queue: BuildQueueStore
    let transfers: TransferQueueStore
    var onSelectGames: () -> Void = {}
    @Binding var extrasOpen: Bool
    @Binding var logOpen: Bool
    var allStepsOpen: Binding<Bool> = .constant(false)
    @Binding var confirmingCancel: Bool
    var onCancelBuild: () -> Void = {}
    var onViewGame: () -> Void = {}
    var onPlayGame: (() -> Void)? = nil
    var onPlayQueuedGame: (String) -> Void = { _ in }
    var queuePlayEnabled = true
    var editingResult: Binding<Bool> = .constant(false)
    var onOpenSettings: () -> Void = {}
    @State private var confirmingQueueCancel = false
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func queueIcon(_ entry: QueueEntry) -> NSImage? {
        if let game = library?.games.first(where: { $0.id == entry.gameID }), !game.appPath.isEmpty,
           let icon = NSImage(contentsOfFile: game.appPath + "/Contents/Resources/AppIcon.icns") { return icon }
        guard let library else { return nil }
        return NSImage(contentsOf: library.artworkDirectory.appendingPathComponent(entry.titleID.uppercased()).appendingPathComponent("icon.jpg"))
    }

    private func canPlayQueued(_ game: QueueGame) -> Bool {
        game.entries.contains { $0.target == BuildTarget.mac && $0.status == .done }
            && library?.games.first(where: { $0.titleID == game.titleID })?.isReady == true
    }

    private var hasActiveTransfer: Bool {
        switch build.send { case .sending, .copying: return true; default: return false }
    }
    private var processActive: Bool { !hasActiveTransfer && ((running && build.buildingGame) || (queue.isAdvancing && queue.packaging.isEmpty)) }
    private var completionActive: Bool { build.completionStatus != nil && !editingResult.wrappedValue && !queue.active && !queue.hasWaiting && queue.running == nil }
    private var queueReview: Bool { !running && !queue.active && (queue.hasWaiting || queue.games.contains(where: \.retryable)) }
    private var lastStep: Int { build.target == BuildTarget.mac ? 1 : 2 }
    private var showingActions: Bool { step >= lastStep || queue.hasWaiting || running || build.done || build.failure != nil }
    private var labels: [String] {
        [loc.t("section.files"), loc.t("section.target")] + (build.target == BuildTarget.mac ? [] : [loc.t("dev.section")])
    }
    var body: some View {
        VStack(spacing: 0) {
            if queueReview {
                BuildQueueHero(games: queue.games.filter { $0.waiting || $0.running || $0.retryable }, artwork: queueIcon, onSelectGames: onSelectGames)
            } else {
                BuildMetadataHero(build: build, library: library, artworkStore: artworkStore,
                                  queueGames: (running || queue.active) ? queue.games.filter { $0.running || $0.waiting } : [], queueArtwork: queueIcon,
                                  platformTargets: queue.games.first { $0.titleID == build.gameTitleID }?.entries.map(\.target) ?? [])
            }
            GeometryReader { viewport in
            LauncherPageScroll(memoryKey: "builds.flow.\(step)") {
                if completionActive {
                    OutcomeCard(build: build, devices: devices, onViewGame: onViewGame, onPlayGame: onPlayGame)
                    if build.completionStatus == .exported || build.completionStatus == .needsData {
                        CardGroup(loc.t("result.next")) { ExportSteps(build: build, devices: devices, resultOnly: true) }
                    }
                    if !queue.isEmpty { BuildQueueCard(queue: queue, artwork: queueIcon, onSelectGames: onSelectGames, playEnabled: queuePlayEnabled, canPlay: canPlayQueued, onPlay: { onPlayQueuedGame($0.titleID) }) }
                    TransferCard(transfers: transfers) { build.revealTransfer($0) }
                    ShellCopyCard(devices: devices)
                    if logOpen { BuildLogView(log: build.log, placeholder: loc.t("log.placeholder")) }
                } else if running || processActive {
                    if processActive { BuildProcessCard(build: build, availableHeight: viewport.size.height, logOpen: logOpen) }
                    else { ProgressCard(build: build) }
                } else {
                    if queueReview {
                        BuildQueueCard(queue: queue, showsHeading: false, artwork: queueIcon, onSelectGames: onSelectGames, playEnabled: queuePlayEnabled, canPlay: canPlayQueued, onPlay: { onPlayQueuedGame($0.titleID) })
                        if queue.hasIOS { InstallCard(devices: devices, build: build, forQueue: true) }
                    } else if step == 0 {
                        FilesCard(build: build, library: library, artworkStore: artworkStore, extrasOpen: $extrasOpen)
                    } else if step == 1 {
                        TargetCard(build: build)
                    }
                    if step == 2 && !queueReview { InstallCard(devices: devices, build: build) }
                }
                if showingActions && !completionActive {
                    // Existing operations remain reachable without forcing a new source selection.
                    if (running && !processActive) || (!queueReview && step != 2 && (build.done || build.failure != nil)) { InstallCard(devices: devices, build: build) }
                    if !queue.isEmpty && !queueReview { BuildQueueCard(queue: queue, artwork: queueIcon, onSelectGames: onSelectGames, playEnabled: queuePlayEnabled, canPlay: canPlayQueued, onPlay: { onPlayQueuedGame($0.titleID) }) }
                    TransferCard(transfers: transfers) { build.revealTransfer($0) }
                    if !processActive && (running || (step >= lastStep && (build.done || build.failure != nil || !build.stages.isEmpty || logOpen || BuildNotifier.shared.showLog))) {
                        LogCard(log: build.log, devices: devices, isOpen: $logOpen,
                                showRequests: BuildNotifier.shared.$showLog.eraseToAnyPublisher(),
                                didShow: { BuildNotifier.shared.showLog = false })
                    }
                    ShellCopyCard(devices: devices)
                    BuildFailureCard(m: build)
                    if !running && (build.done || build.failure != nil) { ProgressCard(build: build) }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: completionActive)
            }
        }
        .sheet(isPresented: allStepsOpen, onDismiss: { pad.scope = "main"; if pad.visible { pad.focused = "set.build.options" } }) {
            BuildProcessStepsSheet(build: build) { allStepsOpen.wrappedValue = false; pad.scope = "main" }
                .environmentObject(loc).environmentObject(pad)
        }
        .environment(\.launcherSectionTitleFont, .manrope(30, .bold))
        .safeAreaInset(edge: .bottom, spacing: 0) { if !processActive && !completionActive { footer } }
        .sheet(isPresented: $confirmingCancel, onDismiss: { pad.scope = "main" }) {
            LauncherConfirmSheet(title: loc.t("flow.cancelTitle"), subtitle: build.gameName, note: loc.t("flow.cancelNote"),
                                 cancelTitle: loc.t("saves.cancel"), confirmTitle: loc.t("flow.cancel"), destructive: true,
                                 scope: "canceldraft", cancel: { confirmingCancel = false; pad.scope = "main"; if pad.visible { pad.focused = "set.build.options" } },
                                 confirm: { confirmingCancel = false; pad.scope = "main"; cancelDraft() })
                .environmentObject(loc).environmentObject(pad)
        }
        .sheet(isPresented: $confirmingQueueCancel, onDismiss: { pad.scope = "main" }) {
            LauncherConfirmSheet(title: String(format: loc.t("queue.cancelConfirm"), queue.queued.count), subtitle: "", note: "",
                cancelTitle: loc.t("queue.keep"), confirmTitle: loc.t("queue.cancel"), destructive: true, scope: "queuecancel",
                cancel: { confirmingQueueCancel = false }, confirm: { confirmingQueueCancel = false; queue.cancelQueued() })
                .environmentObject(loc).environmentObject(pad)
        }
        .onChange(of: confirmingQueueCancel) { open in pad.scope = open ? "queuecancel" : "main" }
        .background { if !showingActions || completionActive { Color.clear.staleFrameworksPrompt(build) } }
        .onAppear { if queue.hasWaiting { step = 1 } }
        .onChange(of: queue.hasWaiting) { waiting in if waiting { step = max(1, step) } }
        .onChange(of: completionActive) { completed in
            if completed && pad.visible && pad.scope == "main" { pad.focused = "set.build.done.library" }
        }
        .onChange(of: build.basePath) { path in if step == 0, pad.visible, !path.isEmpty { pad.focused = "set.build.file.base" } }
        .onChange(of: build.target) { _ in step = min(step, lastStep) }
        .onChange(of: BuildNotifier.shared.showLog) { show in if show { step = lastStep; logOpen = true; BuildNotifier.shared.showLog = false } }
        .onChange(of: running) { active in if active { editingResult.wrappedValue = false } else { allStepsOpen.wrappedValue = false } }
        .onChange(of: logOpen) { _ in if pad.visible { pad.focused = "set.build.options" } }
    }
    private var footer: some View {
        VStack(spacing: 0) {
            if !running && !queueReview {
                GeometryReader { box in
                    Capsule().fill(LauncherPalette.secondaryText.opacity(0.15))
                        .overlay(alignment: .leading) {
                            Capsule().fill(LauncherPalette.text).frame(width: box.size.width * CGFloat(min(step, lastStep) + 1) / CGFloat(lastStep + 1))
                        }
                }.frame(height: 4).accessibilityLabel(labels[min(step, lastStep)])
                    .accessibilityValue(String(format: loc.t("onboarding.stepCount"), min(step, lastStep) + 1, lastStep + 1))
            }
            HStack(spacing: 12) {
                if !queue.isEmpty {
                    Button(loc.t("queue.cancel")) { confirmingQueueCancel = true }
                        .disabled(queue.queued.isEmpty)
                        .padTarget("set.build.queue.cancel", scope: "main", enabled: !queue.queued.isEmpty) { confirmingQueueCancel = true }
                }
                if step > 0 && !running && !queueReview {
                    Button(loc.t("onboarding.back")) { move(-1) }
                        .padTarget("set.build.previous", scope: "main", activate: { move(-1) })
                }
                Spacer(minLength: 12)
                if showingActions {
                    if !queueReview || queue.hasWaiting { ActionCard(build: build, dependencies: dependencies, repo: repo) }
                } else {
                    Text(labels[min(step, lastStep)]).font(.manrope(12)).foregroundStyle(.secondary)
                    Button { move(1) } label: {
                        Label(loc.t("flow.next"), systemImage: "chevron.right").padding(.horizontal, 18).frame(height: LauncherControl.height)
                    }.buttonStyle(LauncherActionButtonStyle())
                        .keyboardShortcut(pad.scope == "main" ? KeyboardShortcut(.return, modifiers: []) : nil)
                        .disabled(step == 0 && !build.slot("base").ok && build.gameFolder == nil)
                        .padTarget("set.build.next", scope: "main", focusColor: LauncherPalette.onCream, enabled: step != 0 || build.slot("base").ok || build.gameFolder != nil, activate: { move(1) })
                }
            }.padding(.horizontal, 40).padding(.vertical, 16).frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
        }.background(LauncherPalette.background).buttonStyle(LauncherSecondaryButtonStyle())
    }
    private func move(_ delta: Int) {
        guard !build.running else { return }
        step = max(0, min(lastStep, step + delta))
        if pad.visible { pad.focused = step == 0 ? (build.basePath.isEmpty ? "set.build.folder" : "set.build.file.base") : step == 1 ? "set.build.target." + build.target : "set.build.install.mode" }
    }
    private func cancelDraft() {
        guard !build.running else { return }
        build.leaveGameFolder()
        for index in build.slots.indices { build.slots[index].paths = []; build.slots[index].problem = ""; build.slots[index].note = "" }
        build.gameDir = ""; build.done = false; build.doneNote = ""; build.stages = []; build.failure = nil; build.macAppPath = ""
        step = 0
        if pad.visible { pad.focused = "set.build.folder" }
        onCancelBuild()
    }
}
