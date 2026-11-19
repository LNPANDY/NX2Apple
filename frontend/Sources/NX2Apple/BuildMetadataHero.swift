import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Metadata is optional presentation. Source validation and build state remain in BuildStore.
struct BuildMetadataHero: View {
    @ObservedObject var build: BuildStore
    var library: GameLibrary?
    var artworkStore: ArtworkStore = .shared
    var queueGames: [QueueGame] = []
    var queueArtwork: (QueueEntry) -> NSImage? = { _ in nil }
    var platformTargets: [String] = []
    @State private var queueIcons: [String: NSImage] = [:]
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var reveal: Double { build.running && build.buildingGame ? min(max(build.gameTitleID == titleID ? (build.overallProgress ?? 0) : 0, 0), 1) : 1 }   // grey only while the build runs, in colour idle and finished (#1458)
    var artworkGames: [QueueGame] {
        guard let current = queueGames.first(where: \.running) else { return Array(queueGames.prefix(4)) }
        return Array(([current] + queueGames.filter { $0.id != current.id }).prefix(4))
    }
    private var queuedGame: QueueGame? { artworkGames.first }
    private var titleID: String? { queuedGame?.titleID ?? build.gameTitleID }
    @State private var queueBanners: [String: NSImage] = [:]
    private var shownBanner: NSImage? { titleID.flatMap { queueBanners[$0] } ?? (bannerID == titleID ? banner : nil) }
    @State private var metadataName: String?
    @State private var icon: NSImage?
    @State private var banner: NSImage?
    @State private var bannerID: String?
    private var game: LibraryGame? { library?.games.first { $0.titleID == titleID } }

    var body: some View {
        HStack(spacing: 22) {
            if !build.basePath.isEmpty || build.gameFolder != nil {
                if !queueGames.isEmpty {
                    QueueArtworkStack(items: artworkGames.map { QueueArtworkItem(id: $0.titleID, image: queueIcons[$0.titleID]) }, size: 96)
                } else {
                Group {
                    if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "gamecontroller.fill").font(.system(size: 30)).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.25)) }
                }.frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                BuildPlatformChip(targets: platformTargets.isEmpty ? [build.running ? build.runningTarget : build.target] : platformTargets)
                ZStack(alignment: .leading) {
                    Text(game?.displayName(loc.lang) ?? queuedGame?.entries.first?.name ?? metadataName ?? (build.gameName.isEmpty ? loc.t("build.heading") : build.gameName))
                        .font(.manrope(30, .bold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .id(titleID).transition(LibraryHeroTransition.blurredMetadata(reduceMotion: reduceMotion))
                }.animation(LibraryHeroTransition.queue(reduceMotion: reduceMotion), value: titleID)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 28).padding(.bottom, 28).padding(.horizontal, 40).frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: 176)
        .foregroundStyle(.white)
        .background {
            GeometryReader { box in
                ZStack {
                    Color.black
                    ZStack {
                        if let shownBanner {
                            BuildHeroReveal(image: shownBanner, progress: reveal)
                                .id((titleID ?? "") + build.runningTarget).transition(.opacity)
                        }
                    }.animation(LibraryHeroTransition.queue(reduceMotion: reduceMotion), value: (titleID ?? "") + build.runningTarget)
                    // the artwork sharp and dimmed, darker where the title sits, fading into the page at the bottom (#1458)
                    LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .black.opacity(0.45), location: 0.55),
                                           .init(color: .black.opacity(0.3), location: 1)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, LauncherPalette.background], startPoint: .center, endPoint: .bottom)
                }.clipped()
            }
        }
        .task(id: artworkGames.map(\.id)) {
            for game in artworkGames {
                if let image = queueArtwork(game.entries[0]) { queueIcons[game.titleID] = image }
                if let record = library?.games.first(where: { $0.titleID == game.titleID }),
                   let image = GameLibrary.artwork(for: record, repo: "", banners: artworkStore.directory) { queueBanners[game.titleID] = image }
            }
        }
        .task(id: (titleID ?? "") + loc.lang.code) {
            icon = nil; metadataName = nil
            guard let id = titleID else { return }
            if let game, let image = GameLibrary.artwork(for: game, repo: "", banners: artworkStore.directory) {
                banner = image; bannerID = id
            }
            let iconURL = await artworkStore.fetchIcon(id, language: loc.lang.code)
            guard !Task.isCancelled, titleID == id else { return }
            if let iconURL { icon = NSImage(contentsOf: iconURL) }
            if game == nil {
                let name = await artworkStore.cachedName(id, language: loc.lang.code)
                guard !Task.isCancelled, titleID == id else { return }
                metadataName = name
            }
            if bannerID != id {
                _ = await artworkStore.fetchMissing([id], language: loc.lang.code, waits: true)
                guard !Task.isCancelled, titleID == id else { return }
                if let url = ArtworkStore.cachedBanner(id, in: artworkStore.directory), let image = NSImage(contentsOf: url) { banner = image; bannerID = id }
            }

        }
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
        HStack(spacing: 24) {
            QueueArtworkStack(items: games.prefix(4).map { QueueArtworkItem(id: $0.titleID, image: icons[$0.id]) }, size: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(games.count == 1 ? loc.t("queue.oneGame") : String(format: loc.t("library.gameCount"), games.count)).font(.manrope(14)).foregroundStyle(.secondary)
                Text(loc.t("queue.title")).font(.manrope(30, .bold)).accessibilityAddTraits(.isHeader)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(loc.t("queue.select"), action: onSelectGames)
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padTarget("set.build.queue.select", scope: "main", activate: onSelectGames)
        }
        .padding(.horizontal, 40).padding(.vertical, 28).frame(maxWidth: 900)
        .frame(maxWidth: .infinity, minHeight: 176)
        .background {
            GeometryReader { box in
                LibraryFallbackArtwork(size: box.size)
            }.clipped()
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

private struct BuildHeroReveal: View {
    let image: NSImage
    let progress: Double
    var body: some View {
        GeometryReader { box in
            ZStack {
                artwork(box.size).saturation(0)
                artwork(box.size).mask { BuildProgressRevealMask(progress: progress) }
            }.clipped()
        }
    }
    private func artwork(_ size: CGSize) -> some View {
        Image(nsImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height)
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
