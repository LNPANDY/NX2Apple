import SwiftUI
import NXCore
import NXModel
import NXLauncher

struct BuildActivityFooter: View {
    @ObservedObject var build: BuildStore
    @ObservedObject var library: GameLibrary
    @ObservedObject var queue: BuildQueueStore
    let repo: String
    var artworkStore: ArtworkStore = .shared
    var fetchMetadata = true
    var onOpen: () -> Void = {}
    var onPlay: (() -> Void)? = nil
    var playEnabled = true
    var completedAt: Date? = nil
    var onDismiss: () -> Void = {}
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var icon: NSImage?
    @State private var iconID: String?
    @State private var shopName: String?
    @State private var queuedIcons: [String: NSImage] = [:]

    private var titleID: String? {
        if queue.active, let current = queue.running { return current.titleID }
        if let operation = build.operation { return operation.titleID }
        return build.gameTitleID
    }

    private var game: LibraryGame? {
        guard let id = titleID else { return nil }
        return library.games.first { $0.titleID.caseInsensitiveCompare(id) == .orderedSame }
    }

    private var title: String {
        if let operation = build.operation {
            guard operation.titleID != nil || operation.game != nil else { return loc.t("shell.ipaShared") }
            return game?.displayName(loc.lang) ?? operation.game ?? shopName ?? loc.t("shell.ipaShared")
        }
        return game?.displayName(loc.lang) ?? shopName ?? build.gameName
    }
    private var completed: Bool { !queue.active && !build.running && build.completionStatus != nil }
    private var platformTargets: [String] {
        queue.games.first { $0.titleID == titleID }?.entries.map(\.target) ?? [build.runningTarget]
    }
    private var platformText: String {
        let targets = platformTargets.map(BuildTarget.normalized)
        return loc.t(Set(targets).count > 1 ? "library.chip.both" : targets.first == BuildTarget.mac ? "library.section.mac" : "build.ios")
    }
    private var progress: Double {
        if completed { return 1 }
        let step = stage?.percent.map { $0 / 100 } ?? 0
        return build.buildingGame ? (build.gameTitleID == titleID ? build.overallProgress ?? step : 0) : step
    }
    private var queuedBuild: Bool { build.buildingGame && queue.active }
    private var upcoming: [QueueEntry] {
        queuedBuild ? Array(queue.games.filter { $0.waiting && $0.titleID != titleID }.prefix(3).map { $0.entries[0] }) : []
    }
    private var status: String {
        if completed { return loc.t(build.completionStatus == .needsData ? "result.dataNeeded" : "build.activityComplete") }
        if queuedBuild { return loc.t("queue.building") }
        if let operation = build.operation { return loc.t(operation.kind == .building ? "build.activity" : operation.kind.key) }
        return loc.t(build.stages.contains { $0.id == 1003 && $0.state == .running } ? "activity.transfer" : "build.activity")
    }
    private var stage: Stage? {
        build.stages.last { $0.state == .running }
            ?? build.stages.last { $0.state != .pending }
            ?? build.stages.first
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: open) {
                HStack(spacing: 16) {
                    artworkStack
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status).font(DS.Font.callout).foregroundStyle(LauncherPalette.text).lineLimit(1)
                        ZStack(alignment: .leading) {
                                Text(title).font(.manrope(20, .semibold)).lineLimit(1).truncationMode(.tail)
                                    .id(titleID).transition(LibraryHeroTransition.blurredMetadata(reduceMotion: reduceMotion))
                        }.animation(LibraryHeroTransition.queue(reduceMotion: reduceMotion), value: titleID)
                    }.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                    if !completed {
                        currentStep.padding(.horizontal, 12)
                            .background(LauncherPalette.ink(0.05), in: RoundedRectangle(cornerRadius: 12))
                            .frame(minWidth: 360, maxWidth: 460)
                    }
                }
                .padding(.leading, 24).padding(.trailing, completed ? 0 : 24)
                .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityLabel(loc.t("library.viewBuild"))
            .accessibilityValue([status, title, platformText, completed ? nil : stage?.displayName(loc.t), completed ? nil : stage?.percent.map { "\(Int($0))%" }].compactMap { $0 }.joined(separator: ", "))
            .help(loc.t("library.viewBuild"))
            .padTarget("build.activity", scope: "main", radius: 0, activate: open)
            if completed {
                HStack(spacing: 12) {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(LauncherIconButtonStyle())
                        .accessibilityLabel(loc.t("build.dismissActivity")).help(loc.t("build.dismissActivity"))
                        .padTarget("build.activity.dismiss", scope: "main", activate: dismiss)
                    if onPlay != nil {
                        Button(action: play) {
                            Label(loc.t("library.play"), systemImage: "play.fill")
                                .font(DS.Font.bodyStrong).padding(.horizontal, 18).frame(height: LauncherControl.height)
                        }.buttonStyle(LauncherActionButtonStyle()).disabled(!playEnabled)
                            .padTarget("build.activity.play", scope: "main", focusColor: LauncherPalette.onCream, enabled: playEnabled, activate: play)
                    }
                }.padding(.trailing, 24)
            }
        }
        .foregroundStyle(LauncherPalette.text)
        // a solid surface under a hairline, no artwork and no blur behind it (#1458)
        .background(LauncherPalette.surface.accessibilityHidden(true).allowsHitTesting(false))
        .overlay(alignment: .top) {   // the hairline doubles as the build's progress, in the accent
            GeometryReader { line in
                ZStack(alignment: .leading) {
                    LauncherPalette.hairline
                    if !completed { LauncherPalette.accent.opacity(0.7).frame(width: line.size.width * min(max(progress, 0), 1)) }
                }
            }.frame(height: 1).allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) { if completed, let completedAt { BuildCompletionTimerStroke(startedAt: completedAt) } }
        .task(id: upcoming) {
            for entry in upcoming {
                let game = library.games.first { $0.titleID.caseInsensitiveCompare(entry.titleID) == .orderedSame }
                if let image = squareArtwork(for: game, titleID: entry.titleID) { queuedIcons[entry.titleID] = image }
            }
        }
        .task(id: ArtworkRequest(operation: build.operation, titleID: titleID, game: game, repo: repo, language: loc.lang.code)) {
            icon = nil; shopName = nil
            guard let id = titleID else { return }
            let record = game ?? LibraryGame(titleID: id, name: title)
            icon = squareArtwork(for: game, titleID: id); iconID = id
            guard fetchMetadata else { return }
            _ = await artworkStore.fetchMissing([id], language: loc.lang.code, waits: true)
            guard !Task.isCancelled, titleID == id else { return }
            let iconURL = await artworkStore.fetchIcon(id, language: loc.lang.code)
            guard !Task.isCancelled, titleID == id else { return }
            shopName = artworkStore.cachedName(id, language: loc.lang.code)
            if let iconURL { icon = ArtworkImages.shared.image(at: iconURL, maxPixel: 192) }
        }
    }

    private var artworkStack: some View {
        QueueArtworkStack(items: [QueueArtworkItem(id: titleID ?? "current", image: (iconID == titleID ? icon : nil) ?? titleID.flatMap { queuedIcons[$0] })]
                          + upcoming.map { QueueArtworkItem(id: $0.titleID, image: queuedIcons[$0.titleID]) }, size: 64)
            .overlay(alignment: .bottomTrailing) {
                if completed { ArtworkOutcomeBadge(build.completionStatus == .needsData ? .warning : .success, artworkSize: 64) }
            }
    }

    private func squareArtwork(for game: LibraryGame?, titleID: String) -> NSImage? {
        if let game, let image = GameLibrary.appIcon(for: game, banners: library.artworkDirectory, maxPixel: ArtworkImages.iconPixels) {
            return image
        }
        if let cached = BannerCache.cachedIcon(titleID, in: library.artworkDirectory),
           let image = ArtworkImages.shared.image(at: cached, maxPixel: ArtworkImages.iconPixels) {
            return image
        }
        if let banner = ArtworkStore.cachedBanner(titleID, in: library.artworkDirectory) {
            return ArtworkImages.shared.image(at: banner, maxPixel: ArtworkImages.iconPixels, squareCrop: true)
        }
        return nil
    }

    private var currentStep: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach([BuildTarget.mac, BuildTarget.ios].filter { platformTargets.map(BuildTarget.normalized).contains($0) }, id: \.self) { target in
                    Label(loc.t(target == BuildTarget.mac ? "library.section.mac" : "build.ios"), systemImage: target == BuildTarget.mac ? "desktopcomputer" : "iphone")
                        .font(DS.Font.bodyStrong).fixedSize()
                }
            }
            Rectangle().fill(LauncherPalette.secondaryText.opacity(0.4)).frame(width: 1, height: 24).accessibilityHidden(true)
            Group {
                if stage?.state == .done { Image(systemName: "checkmark.circle.fill").foregroundStyle(LauncherPalette.ready) }
                else if stage?.state == .failed { Image(systemName: "xmark.circle.fill").foregroundStyle(LauncherPalette.danger) }
                else if stage?.state == .pending { Image(systemName: "circle").foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small).accessibilityLabel(stage?.displayName(loc.t) ?? loc.t("library.preparing"))
                        .accessibilityHint(loc.t("prog.stageProgress")) }
            }
            .font(.system(size: 18)).frame(width: 20, height: 20)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage?.state)
            Text(stage?.displayName(loc.t) ?? loc.t("library.preparing")).font(DS.Font.body).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(stage?.state == .running ? stage?.clock(at: context.date, left: loc.t("prog.etaEstimate")) ?? "" : "")
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).monospacedDigit()
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }.layoutPriority(1)
            Text(stage?.state == .running ? stage?.percent.map { "\(Int($0))%" } ?? "" : "")
                .font(DS.Font.body).monospacedDigit().frame(minWidth: 44, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 44)
    }

    private func open() { if isEnabled && (build.running || queue.active || completed) { onOpen() } }
    private func dismiss() { if isEnabled && completed { onDismiss() } }
    private func play() {
        guard isEnabled, completed, playEnabled, let onPlay else { return }
        onPlay()
        if !queue.hasWaiting && queue.running == nil { onDismiss() }
    }

    private struct ArtworkRequest: Equatable {
        let operation: ActiveOperation?
        let titleID: String?
        let game: LibraryGame?
        let repo: String
        let language: String
    }
}

struct BuildFooterReveal: View {
    let image: NSImage
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                artwork(size: geometry.size).saturation(0)
                    .overlay(Color.black.opacity(0.55))
                artwork(size: geometry.size)
                    .overlay(Color.black.opacity(0.35))
                    .mask { BuildProgressRevealMask(progress: progress) }
            }
        }
        .background(LauncherPalette.background).clipped().accessibilityHidden(true)
    }

    private func artwork(size: CGSize) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
    }
}
