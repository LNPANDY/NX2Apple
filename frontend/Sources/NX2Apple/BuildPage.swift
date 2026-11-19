import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// Unified single-screen Build workbench: combines the hero, stage progress, and outcome cards
/// with direct access to engine switching, game files, target, iOS install/export, batch queue, and logs.
struct BuildPage: View {
    var library: GameLibrary? = nil
    var artworkStore: ArtworkStore = .shared
    var fetchMetadata = true
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
    @State private var showRunningSetup = false
    @State private var confirmingQueueCancel = false
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func queueIcon(_ entry: QueueEntry) -> NSImage? {
        guard let library else { return nil }
        if let game = library.games.first(where: { $0.id == entry.gameID }),
           let icon = GameLibrary.appIcon(for: game, banners: library.artworkDirectory, maxPixel: ArtworkImages.iconPixels) {
            return icon
        }
        if let cached = BannerCache.cachedIcon(entry.titleID, in: library.artworkDirectory),
           let icon = ArtworkImages.shared.image(at: cached, maxPixel: ArtworkImages.iconPixels) {
            return icon
        }
        if let banner = ArtworkStore.cachedBanner(entry.titleID, in: library.artworkDirectory) {
            return ArtworkImages.shared.image(at: banner, maxPixel: ArtworkImages.iconPixels, squareCrop: true)
        }
        return nil
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
    private var stagingQueue: Bool { !running && !queue.active && queue.hasWaiting }
    private var queueReview: Bool { !running && !queue.active && (queue.hasWaiting || queue.games.contains(where: \.retryable)) }
    private var hasHeroContext: Bool {
        !build.basePath.isEmpty || build.gameFolder != nil || running || processActive || build.done || build.completionStatus != nil || build.failure != nil || !queue.isEmpty
    }

    var body: some View {
        LauncherPageScroll(memoryKey: "builds.page") {
            topHeader
            if running || processActive {
                if processActive {
                    BuildProcessCard(build: build, logOpen: false, onShowSteps: { allStepsOpen.wrappedValue = true })
                } else {
                    ProgressCard(build: build)
                }
                CardGroup("") {
                    CardDisclosure(loc.t("section.setup"), detail: build.gameName, isOpen: showRunningSetup) { showRunningSetup.toggle() }
                        .accessibilityLabel(loc.t("section.setup"))
                        .accessibilityValue([build.gameName, loc.t(showRunningSetup ? "onboarding.expanded" : "onboarding.collapsed")]
                            .filter { !$0.isEmpty }.joined(separator: ", "))
                        .padTarget("set.build.runningSetup", scope: "main") { showRunningSetup.toggle() }
                }
                .onDisappear { showRunningSetup = false }
            }
            if completionActive && !running && !processActive {
                OutcomeCard(build: build, devices: devices, onViewGame: onViewGame, onPlayGame: onPlayGame)
                let inlineExportShown = !stagingQueue && build.target != BuildTarget.mac && devices.exportIPA
                if (build.completionStatus == .exported || build.completionStatus == .needsData) && !inlineExportShown {
                    CardGroup(loc.t("result.next")) { ExportSteps(build: build, devices: devices, resultOnly: true) }
                }
            }
            if (!running && !processActive) || showRunningSetup {
                EngineSwitcherCard(build: build)
                SetupHintCard(repo: repo, dependencies: dependencies, usesExternalUpstream: build.usesExternalUpstreamRepo, onOpenSettings: onOpenSettings)
                if stagingQueue {
                    queueSection(showsHeading: !queueReview)
                } else {
                    FilesCard(build: build, library: library, artworkStore: artworkStore, fetchMetadata: fetchMetadata, extrasOpen: $extrasOpen)
                    TargetCard(build: build)
                }
            }
            if stagingQueue {
                if queue.hasIOS { InstallCard(devices: devices, build: build, showLocked: showRunningSetup, forQueue: true) }
            } else {
                InstallCard(devices: devices, build: build, showLocked: showRunningSetup)
            }
            if !stagingQueue {
                queueSection(showsHeading: !queueReview)
            }
            TransferCard(transfers: transfers) { build.revealTransfer($0) }
            LogCard(log: build.log, devices: devices, isOpen: $logOpen,
                    showRequests: BuildNotifier.shared.$showLog.eraseToAnyPublisher(),
                    didShow: { BuildNotifier.shared.showLog = false })
            if !processActive {
                ActionCard(build: build, dependencies: dependencies, repo: repo)
            }
            Group {
                ShellCopyCard(devices: devices)
                BuildFailureCard(m: build)
                if !running && !processActive && !build.stages.isEmpty && (build.done || build.failure != nil) {
                    ProgressCard(build: build)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: completionActive)
        .sheet(isPresented: allStepsOpen, onDismiss: { pad.scope = "main"; if pad.visible { pad.focused = "set.build.steps" } }) {
            BuildProcessStepsSheet(build: build) { allStepsOpen.wrappedValue = false; pad.scope = "main" }
                .environmentObject(loc).environmentObject(pad)
        }
        .sheet(isPresented: $confirmingCancel, onDismiss: { pad.scope = "main" }) {
            LauncherConfirmSheet(title: loc.t("flow.cancelTitle"), subtitle: build.gameName, note: loc.t("flow.cancelNote"),
                                 cancelTitle: loc.t("saves.cancel"), confirmTitle: loc.t("flow.cancel"), destructive: true,
                                 scope: "canceldraft", cancel: { confirmingCancel = false; pad.scope = "main" },
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
        .background { if processActive { Color.clear.staleFrameworksPrompt(build) } }
        .onChange(of: completionActive) { completed in
            if completed && pad.visible && pad.scope == "main" { pad.focused = "set.build.done.library" }
        }
        .onChange(of: BuildNotifier.shared.showLog) { show in if show { logOpen = true; BuildNotifier.shared.showLog = false } }
        .onChange(of: running) { active in if active { editingResult.wrappedValue = false } else { allStepsOpen.wrappedValue = false; showRunningSetup = false } }
    }

    @ViewBuilder private var topHeader: some View {
        if queueReview {
            BuildQueueHero(games: queue.games.filter { $0.waiting || $0.running || $0.retryable }, artwork: queueIcon, onSelectGames: onSelectGames)
        } else if hasHeroContext {
            BuildMetadataHero(build: build, library: library, artworkStore: artworkStore, fetchMetadata: fetchMetadata,
                              queueGames: (running || queue.active) ? queue.games.filter { $0.running || $0.waiting } : [], queueArtwork: queueIcon,
                              platformTargets: queue.games.first { $0.titleID == build.gameTitleID }?.entries.map(\.target) ?? [])
        } else {
            CardPageHeading(loc.t("build.heading"), note: loc.t("build.intro"))
        }
    }

    @ViewBuilder private func queueSection(showsHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BuildQueueCard(queue: queue, showsHeading: showsHeading, artwork: queueIcon, onSelectGames: onSelectGames,
                           playEnabled: queuePlayEnabled, canPlay: canPlayQueued, onPlay: { onPlayQueuedGame($0.titleID) })
            if !queue.queued.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    Button(loc.t("queue.cancel")) { confirmingQueueCancel = true }
                        .buttonStyle(LauncherSecondaryButtonStyle()).fixedSize()
                        .padTarget("set.build.queue.cancel", scope: "main", activate: { confirmingQueueCancel = true })
                }
            }
        }
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
