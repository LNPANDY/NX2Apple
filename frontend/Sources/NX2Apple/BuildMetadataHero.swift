import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The build pages' compact header (#1458): the app icon (or the fanned stack of the queued games), the title and one status line,
/// with an optional trailing action. The build pages are task pages: no artwork hero, the icon fills with colour as the build runs.
/// Metadata is optional presentation. Source validation and build state remain in BuildStore.
struct BuildMetadataHero<Trailing: View>: View {
    @ObservedObject var build: BuildStore
    var library: GameLibrary?
    var artworkStore: ArtworkStore = .shared
    var queueGames: [QueueGame] = []
    var queueArtwork: (QueueEntry) -> NSImage? = { _ in nil }
    var platformTargets: [String] = []
    /// The line under the title: the wizard's step, or the build's state. Empty works it out from the build.
    var statusLine: String = ""
    @ViewBuilder var trailing: () -> Trailing
    @State private var queueIcons: [String: NSImage] = [:]
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Grey only while the build runs, in colour idle and finished (#1458).
    private var reveal: Double { build.running && build.buildingGame ? min(max(build.gameTitleID == titleID ? (build.overallProgress ?? 0) : 0, 0), 1) : 1 }
    var artworkGames: [QueueGame] {
        guard let current = queueGames.first(where: \.running) else { return Array(queueGames.prefix(4)) }
        return Array(([current] + queueGames.filter { $0.id != current.id }).prefix(4))
    }
    private var queuedGame: QueueGame? { artworkGames.first }
    private var titleID: String? { queuedGame?.titleID ?? build.gameTitleID }
    @State private var metadataName: String?
    @State private var icon: NSImage?
    private var game: LibraryGame? { library?.games.first { $0.titleID == titleID } }
    private var chosen: Bool { !build.basePath.isEmpty || build.gameFolder != nil || queuedGame != nil }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            if chosen {
                if artworkGames.count > 1 {
                    QueueArtworkStack(items: artworkGames.map { QueueArtworkItem(id: $0.titleID, image: queueIcons[$0.titleID]) }, size: DS.Control.headerIcon)
                } else {
                    BuildIconReveal(image: icon ?? queuedGame.flatMap { queueIcons[$0.titleID] }, progress: reveal)
                        .id((titleID ?? "") + build.runningTarget)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(game?.displayName(loc.lang) ?? queuedGame?.entries.first?.name ?? metadataName ?? (build.gameName.isEmpty ? loc.t("build.addGame") : build.gameName))
                    .font(DS.Font.title).foregroundStyle(DS.Color.textPrimary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                let line = statusLine.isEmpty ? BuildHeaderLine.text(build, loc.t) : statusLine
                if !line.isEmpty {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        Text(statusLine.isEmpty ? BuildHeaderLine.text(build, loc.t, now: context.date) : statusLine)
                            .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1).monospacedDigit()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: artworkGames.map(\.id)) {
            for game in artworkGames {
                if let image = queueArtwork(game.entries[0]) { queueIcons[game.titleID] = image }
            }
        }
        .task(id: (titleID ?? "") + loc.lang.code) {
            icon = nil; metadataName = nil
            guard let id = titleID else { return }
            let iconURL = await artworkStore.fetchIcon(id, language: loc.lang.code)
            guard !Task.isCancelled, titleID == id else { return }
            if let iconURL { icon = NSImage(contentsOf: iconURL) }
            if game == nil {
                let name = await artworkStore.cachedName(id, language: loc.lang.code)
                guard !Task.isCancelled, titleID == id else { return }
                metadataName = name
            }
        }
    }
}

extension BuildMetadataHero where Trailing == EmptyView {
    init(build: BuildStore, library: GameLibrary? = nil, artworkStore: ArtworkStore = .shared, queueGames: [QueueGame] = [],
         queueArtwork: @escaping (QueueEntry) -> NSImage? = { _ in nil }, platformTargets: [String] = [], statusLine: String = "") {
        self.init(build: build, library: library, artworkStore: artworkStore, queueGames: queueGames, queueArtwork: queueArtwork,
                  platformTargets: platformTargets, statusLine: statusLine, trailing: { EmptyView() })
    }
}

/// The header's status line: "Building for Mac · Shaders · About 2 min left", "Built for Mac", "Build failed · Shaders".
@MainActor enum BuildHeaderLine {
    static func platform(_ target: String, _ t: (String) -> String) -> String {
        t(BuildTarget.normalized(target) == BuildTarget.mac ? "library.section.mac" : "build.ios")
    }
    static func text(_ build: BuildStore, _ t: (String) -> String, now: Date = Date()) -> String {
        let target = platform(build.running ? build.runningTarget : build.target, t)
        if build.running {
            let stage = build.stages.last { $0.state == .running }
            let eta = stage.flatMap { $0.remaining(at: now) }.map { String(format: t("prog.etaEstimate"), BuildProgress.duration($0)) }
            return ([String(format: t("build.header.building"), target)] + [stage?.displayName(t), eta].compactMap { $0 }).joined(separator: " · ")
        }
        if build.failure != nil || build.stages.contains(where: { $0.state == .failed }) {
            return ([t("build.header.failed")] + [build.stages.last { $0.state == .failed }?.displayName(t)].compactMap { $0 }).joined(separator: " · ")
        }
        if build.done || build.completionStatus != nil { return String(format: t("build.header.built"), target) }
        return ""
    }
}

/// The app icon at header size. While a build runs it is grey and fills with colour from the leading edge as the build moves on.
struct BuildIconReveal: View {
    let image: NSImage?
    let progress: Double
    var body: some View {
        ZStack {
            tile.saturation(0)
            tile.mask { BuildProgressRevealMask(progress: progress) }
        }
        .frame(width: DS.Control.headerIcon, height: DS.Control.headerIcon)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sheet))
        .accessibilityHidden(true)
    }
    private var tile: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: "gamecontroller.fill").font(.system(size: 24)).foregroundStyle(DS.Color.symbolDefault)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.Color.surfaceRaised)
            }
        }.frame(width: DS.Control.headerIcon, height: DS.Control.headerIcon)
    }
}

/// The queue has its own identity, independent of the last single-game draft.
struct BuildQueueHero: View {
    let games: [QueueGame]
    let artwork: (QueueEntry) -> NSImage?
    let onSelectGames: () -> Void
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var icons: [UUID: NSImage] = [:]

    var body: some View {
        HStack(spacing: DS.Space.m) {
            QueueArtworkStack(items: games.prefix(4).map { QueueArtworkItem(id: $0.titleID, image: icons[$0.id]) }, size: DS.Control.headerIcon)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(loc.t("queue.title")).font(DS.Font.title).foregroundStyle(DS.Color.textPrimary).accessibilityAddTraits(.isHeader)
                Text(games.count == 1 ? loc.t("queue.oneGame") : String(format: loc.t("library.gameCount"), games.count))
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(loc.t("queue.select"), action: onSelectGames)
                .buttonStyle(DSSecondaryButtonStyle())
                .padTarget("set.build.queue.select", scope: "main", activate: onSelectGames)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: games.map(\.id))
        .task(id: games.map(\.id)) {
            icons = Dictionary(uniqueKeysWithValues: games.compactMap { game in artwork(game.entries[0]).map { (game.id, $0) } })
        }
    }
}
/// Current work keeps a fixed anchor, with upcoming games receding into the leading gutter.
struct QueueArtworkItem: Identifiable {
    let id: String
    let image: NSImage?
}

struct QueueArtworkStack: View {
    let items: [QueueArtworkItem]
    let size: CGFloat
    @State private var shown: [QueueArtworkItem]?
    @State private var outgoing: QueueArtworkItem?
    @State private var outgoingVisible = true
    @State private var promotionPending = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
                tile(item, index: index + (promotionPending ? 1 : 0))
                    .zIndex(Double(10 - index))
            }
            if let outgoing {
                tile(outgoing, index: 0)
                    .scaleEffect(outgoingVisible || reduceMotion ? 1 : 1 / 0.84)
                    .opacity(outgoingVisible ? 1 : 0)
                    .zIndex(100)
            }
        }
        .frame(width: size, height: size, alignment: .leading)
        .accessibilityHidden(true)
        .onChange(of: items.map(\.image)) { _ in
            if shown == nil || shown?.first?.id == items.first?.id { shown = items }
        }
        .task(id: items.map(\.id)) {
            if shown == nil { shown = items; return }
            guard let current = shown?.first, current.id != items.first?.id else { return }
            // Keep the next tile behind the outgoing one until its exit has finished.
            outgoing = current; outgoingVisible = true; promotionPending = true; shown = items
            await Task.yield()
            withAnimation(.easeOut(duration: 0.14)) { outgoingVisible = false }
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            outgoing = nil
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { promotionPending = false }
        }
    }

    private func tile(_ item: QueueArtworkItem, index: Int) -> some View {
        Group {
            if let image = item.image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: "gamecontroller.fill").font(.system(size: size * 0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(LauncherPalette.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .overlay(Color.black.opacity(index == 0 ? 0 : 0.2), in: RoundedRectangle(cornerRadius: size * 0.15))
        .scaleEffect(index == 0 ? 1 : max(0.7, 0.9 - Double(index) * 0.06))
        .rotation3DEffect(.degrees(index == 0 ? 0 : 22), axis: (x: 0, y: 1, z: 0))
        .offset(x: -CGFloat(index) * size * 0.125)
    }
}


/// Retargets continuously within one run. The caller resets identity for the next game/platform.
struct BuildProgressRevealMask: View {
    let progress: Double
    @State private var displayed: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(progress: Double) {
        self.progress = progress
        _displayed = State(initialValue: Self.target(current: 0, reported: progress))
    }
    static func target(current: Double, reported: Double) -> Double {
        guard reported.isFinite else { return current }
        return max(current, min(max(reported, 0), 1))
    }
    var body: some View {
        Rectangle().scaleEffect(x: displayed, y: 1, anchor: .leading)
            .animation(reduceMotion ? nil : displayed >= 1 ? .easeOut(duration: 0.18) : .spring(response: 0.7, dampingFraction: 1, blendDuration: 0.1), value: displayed)
            .onChange(of: progress) { displayed = Self.target(current: displayed, reported: $0) }
    }
}
