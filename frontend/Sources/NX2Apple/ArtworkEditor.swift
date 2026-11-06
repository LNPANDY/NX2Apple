import AppKit
import ImageIO
import NXCore

/// Everything the artwork editor reaches outside itself, injectable: tests give fakes, so none of them touches the network or the
/// player's folders. The live one is the ArtworkStore and ArtworkImport.
struct ArtworkEditorEnvironment {
    /// The title's screenshots. `retrying` is the player pressing Try again after `.offline`.
    var media: (_ titleID: String, _ retrying: Bool) async -> ArtworkStore.MediaLoad
    var candidate: (_ source: ArtworkChoice.Source, _ titleID: String) async throws -> URL
    var cachedCandidate: (_ source: ArtworkChoice.Source, _ titleID: String) -> URL?
    var banner: (_ titleID: String) -> URL?
    /// Called off the main thread.
    var prepare: (_ file: URL, _ kind: ArtworkImport.Kind, _ directory: URL) throws -> ArtworkImport.Prepared
    var pixelWidth: (_ file: URL) -> Int?
    /// The size the image is drawn at (upright, as ArtworkImages decodes it). Called off the main thread.
    var pixelSize: (_ file: URL) -> CGSize?
    var removeFile: (_ file: URL) -> Void

    static func live(store: ArtworkStore) -> ArtworkEditorEnvironment {
        ArtworkEditorEnvironment(
            media: { await store.media(for: $0, retrying: $1) },
            candidate: { try await store.candidate($0, titleID: $1) },
            cachedCandidate: { ArtworkStore.cachedCandidate($0, titleID: $1, in: store.directory) },
            banner: { ArtworkStore.cachedBanner($0, in: store.directory) },
            prepare: { try ArtworkImport.prepare($0, kind: $1, into: $2) },
            pixelWidth: { url in
                (CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
            },
            pixelSize: { url in
                guard let properties = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
                let turned = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5   // a sideways photo is drawn upright
                return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            },
            removeFile: { try? FileManager.default.removeItem(at: $0) })
    }
}

/// The state behind the artwork panel, with no views: the draft the library shows as a preview. The library is only written by `save`.
@MainActor final class ArtworkEditor: ObservableObject {
    static let columns = 3
    /// How far an arrow key moves the framing point, as a fraction of the image.
    static let nudgeStep = 0.05
    /// The hero's width over its height at the default window (1280 × 900): the page less the collection row, about 1280 × 530.
    /// The library replaces it with the hero's real proportions, which change with the window.
    static let heroBandAspect: CGFloat = 2.4
    /// The cards of the library and the console covers are 1.8 : 1.
    static let thumbnailBandAspect: CGFloat = 1.8

    enum LoadState: Equatable { case loading, loaded, offline, none }
    enum Notice: Equatable { case warning(String), error(String) }
    enum Direction { case left, right, up, down }

    /// One image the player can choose. Its file is nil until it has arrived (a screenshot downloads on demand).
    struct Tile: Identifiable, Equatable {
        let source: ArtworkChoice.Source
        let file: URL?
        let isSelected: Bool
        /// On the thumbnail tab, the tile the hero uses: choosing it makes the thumbnail follow the hero again.
        let isHero: Bool
        let isLowResolution: Bool
        /// The download failed: the tile stays empty and cannot be chosen.
        var isFailed = false
        var isAvailable: Bool { file != nil }

        var id: String {
            switch source {
            case .banner: return "banner"
            case .screenshot(let n): return "screenshot.\(n)"
            case .imported(let name): return "imported." + name
            }
        }
    }

    let gameID: UUID
    let gameName: String
    private let titleID: String
    private let importDirectory: URL
    private let env: ArtworkEditorEnvironment
    private let labels: (String) -> String

    @Published var slot: ArtworkSlot {
        didSet {
            guard slot != oldValue else { return }
            notice = nil
            cursor = tiles.firstIndex { $0.isSelected }
        }
    }
    @Published private(set) var original: GameArtwork
    @Published private(set) var draft: GameArtwork
    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var notice: Notice?
    /// The tile the arrow keys are on: the selected one, or where the last arrow went (a tile that has not arrived cannot be chosen).
    @Published private(set) var cursor: Int?
    /// The hero's width over its height as the library draws it now: the framing is offered and drawn for that band.
    @Published var heroAspect = ArtworkEditor.heroBandAspect

    // Published so a tile redraws as its screenshot arrives, not once every download is done
    @Published private var media: ArtworkStore.Media?
    @Published private var bannerFile: URL?
    @Published private var downloaded: [ArtworkChoice.Source: URL] = [:]
    @Published private var failed: Set<ArtworkChoice.Source> = []
    @Published private var importedFiles: [String]   // the game's own images this session shows, in the order of the grid
    @Published private var importURLs: [String: URL] = [:]
    @Published private var pixelWidths: [String: Int] = [:]
    @Published private var pixelSizes: [URL: CGSize] = [:]   // of the images the framing was asked for
    private var sessionImports: Set<String> = []   // made while the panel was open: Cancel removes those the saved artwork does not use
    private var loadTask: Task<Void, Never>?
    private var closed = false

    init(game: LibraryGame, slot: ArtworkSlot = .hero, artworkDirectory: URL, env: ArtworkEditorEnvironment, labels: @escaping (String) -> String) {
        gameID = game.id
        gameName = game.name
        titleID = game.titleID
        importDirectory = ArtworkStore.customDirectory(for: game.id, in: artworkDirectory)
        self.env = env
        self.labels = labels
        self.slot = slot
        original = game.artwork
        draft = game.artwork
        bannerFile = env.banner(game.titleID)
        importedFiles = [game.artwork.hero, game.artwork.thumbnail].compactMap { if case .imported(let name)? = $0?.source { return name } else { return nil } }
            .reduce(into: []) { names, name in if !names.contains(name) { names.append(name) } }   // one tile when both slots use the file
        for name in importedFiles {   // a name in the game's folder, never a path
            let url = importDirectory.appendingPathComponent(name)
            if name == url.lastPathComponent, FileManager.default.fileExists(atPath: url.path) { importURLs[name] = url }
        }
        cursor = tiles.firstIndex { $0.isSelected }
    }

    deinit { loadTask?.cancel() }


    var isDirty: Bool { draft != original }

    func canReset(_ slot: ArtworkSlot) -> Bool {
        switch slot {
        case .hero: return draft.hero != nil
        case .thumbnail: return draft.thumbnail != nil
        }
    }

    /// With no banner, the first screenshot stands in as the default hero.
    private var defaultHero: ArtworkChoice.Source? {
        if bannerFile != nil { return .banner }
        return media?.screenshots.isEmpty == false ? .screenshot(0) : nil
    }

    private var heroSource: ArtworkChoice.Source? { draft.hero?.source ?? defaultHero }

    private var selectedSource: ArtworkChoice.Source? {
        switch slot {
        case .hero: return heroSource
        case .thumbnail: return draft.thumbnail?.source ?? heroSource
        }
    }

    /// The banner, the screenshots, then the game's own images. The "Choose file…" tile is the view's. Both tabs offer the same images.
    var tiles: [Tile] {
        var sources: [(ArtworkChoice.Source, URL?)] = []
        if let bannerFile { sources.append((.banner, bannerFile)) }
        for n in (media?.screenshots.indices).map({ Array($0) }) ?? [] {
            let source = ArtworkChoice.Source.screenshot(n)
            sources.append((source, downloaded[source]))
        }
        for name in importedFiles { sources.append((.imported(name), importURLs[name])) }
        let selected = selectedSource, hero = heroSource, kind = importKind
        return sources.map { source, file in
            var low = false
            if case .imported(let name) = source, let width = pixelWidths[name] { low = width < kind.lowResolutionWidth }
            return Tile(source: source, file: file, isSelected: source == selected, isHero: slot == .thumbnail && source == hero, isLowResolution: low,
                        isFailed: failed.contains(source))
        }
    }

    /// The list of screenshots is being read: the view shows skeleton tiles after the ones it knows.
    var isLoading: Bool { loadState == .loading }

    func label(for tile: Tile) -> String {
        var parts: [String]
        switch tile.source {
        case .banner: parts = [labels("artwork.banner")]
        case .screenshot(let n): parts = [String(format: labels("artwork.screenshot"), n + 1)]
        case .imported: parts = [labels("artwork.yours")]
        }
        if tile.isHero { parts.append(labels("artwork.heroBadge")) }
        if tile.isLowResolution { parts.append(labels("artwork.lowResBadge")) }
        return parts.joined(separator: ", ")
    }

    var gridLabel: String { labels("artwork.grid." + slot.rawValue) }

    var tileAspect: CGFloat { 16 / 9 }

    private var importKind: ArtworkImport.Kind { slot == .hero ? .hero : .thumbnail }


    /// Makes the tile the slot's choice. A tile whose image has not arrived cannot be chosen.
    @discardableResult func select(_ tile: Tile) -> Bool {
        guard tile.isAvailable else { return false }
        notice = nil
        switch slot {
        case .hero: draft.hero = draft.hero?.source == tile.source ? draft.hero : ArtworkChoice(source: tile.source)
        case .thumbnail: draft.thumbnail = tile.isHero ? nil : (draft.thumbnail?.source == tile.source ? draft.thumbnail : ArtworkChoice(source: tile.source))
        }
        cursor = tiles.firstIndex { $0.id == tile.id }
        return true
    }

    /// Makes an image the choice of a slot, the open tab or not. A thumbnail given the hero's image follows the hero.
    private func choose(_ source: ArtworkChoice.Source, for slot: ArtworkSlot) {
        notice = nil
        switch slot {
        case .hero: if draft.hero?.source != source { draft.hero = ArtworkChoice(source: source) }
        case .thumbnail: draft.thumbnail = source == heroSource ? nil : (draft.thumbnail?.source == source ? draft.thumbnail : ArtworkChoice(source: source))
        }
        cursor = tiles.firstIndex { $0.isSelected }
    }

    func selectCursor() {
        let all = tiles
        if let cursor, all.indices.contains(cursor) { select(all[cursor]) }
    }

    /// An arrow key: moves over the grid by rows of three and chooses what it lands on, as the cards of the library do.
    func move(_ direction: Direction) {
        let all = tiles
        guard !all.isEmpty else { return }
        guard let from = cursor ?? all.firstIndex(where: \.isSelected) else { cursor = 0; selectCursor(); return }
        var to = from
        switch direction {
        case .left: if from % Self.columns > 0 { to = from - 1 }
        case .right: if from % Self.columns < Self.columns - 1, from + 1 < all.count { to = from + 1 }
        case .up: if from >= Self.columns { to = from - Self.columns }
        case .down: if from + Self.columns < all.count { to = from + Self.columns }
        }
        cursor = to
        selectCursor()
    }


    var selectedFile: URL? { tiles.first { $0.isSelected }?.file }

    /// The chosen image's size in pixels, nil until `measureSelected` has read it.
    var framingImageSize: CGSize? { selectedFile.flatMap { pixelSizes[$0] } }

    /// The band the slot's image is cropped to, as a size of the right proportions.
    var framingBand: CGSize { CGSize(width: slot == .hero ? heroAspect : Self.thumbnailBandAspect, height: 1) }

    /// The chosen image is cut by 5 % or more in the slot's band: only then is a point worth choosing.
    var needsFraming: Bool { framingImageSize.map { ArtworkFraming.needsFraming(image: $0, band: framingBand) } ?? false }

    /// The point the slot's crop keeps. A thumbnail that follows the hero shows the hero's.
    var focus: ArtworkFocus { draft.choice(for: slot)?.focus ?? .center }

    var isCentered: Bool { focus == .center }

    /// Reads the chosen image's size off the main thread, once per file.
    func measureSelected() async {
        guard let file = selectedFile, pixelSizes[file] == nil else { return }
        let env = env
        if let size = await Task.detached(operation: { env.pixelSize(file) }).value { pixelSizes[file] = size }
    }

    /// Moves the slot's point, kept inside the image. A thumbnail that followed the hero stops following it, with the hero's image.
    func setFocus(_ point: ArtworkFocus) {
        func unit(_ value: Double) -> Double { (min(max(value, 0), 1) * 1000).rounded() / 1000 }
        let focus = ArtworkFocus(x: unit(point.x), y: unit(point.y))
        guard focus != self.focus else { return }
        // A point moved back to where it was before the panel opened leaves no choice behind: no Reset, nothing to save
        switch slot {
        case .hero:
            guard let source = heroSource else { return }
            let choice = ArtworkChoice(source: source, focus: focus)
            draft.hero = original.hero == nil && source == defaultHero && focus == .center ? nil : choice
        case .thumbnail:
            guard let source = draft.thumbnail?.source ?? heroSource else { return }
            let choice = ArtworkChoice(source: source, focus: focus)
            let follows = source == heroSource && focus == (draft.choice(for: .hero)?.focus ?? .center)
            draft.thumbnail = original.thumbnail == nil && follows ? nil : choice
        }
    }

    func nudge(_ direction: Direction) {
        let step = Self.nudgeStep, current = focus
        switch direction {
        case .left: setFocus(ArtworkFocus(x: current.x - step, y: current.y))
        case .right: setFocus(ArtworkFocus(x: current.x + step, y: current.y))
        case .up: setFocus(ArtworkFocus(x: current.x, y: current.y - step))
        case .down: setFocus(ArtworkFocus(x: current.x, y: current.y + step))
        }
    }

    /// The image is cut at its sides in the slot's band (a picture wider than the band), else at its top and bottom. A drag moves the
    /// point along that axis only, and so does VoiceOver.
    var cropsWidth: Bool {
        guard let image = framingImageSize, image.height > 0 else { return true }
        return image.width / image.height > framingBand.width / framingBand.height
    }

    func adjustFocus(increment: Bool) {
        if cropsWidth { nudge(increment ? .right : .left) } else { nudge(increment ? .down : .up) }
    }

    func recenter() { setFocus(.center) }

    func reset(_ slot: ArtworkSlot) {
        notice = nil
        switch slot {
        case .hero: draft.hero = nil
        case .thumbnail: draft.thumbnail = nil
        }
        cursor = tiles.firstIndex { $0.isSelected }
    }


    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { await load() }
    }

    func retry() {
        loadTask?.cancel()
        loadTask = Task { await load(retrying: true) }
    }

    /// The screenshots are listed, then downloaded one by one: their tiles are there from the list, empty until the file arrives.
    func load(retrying: Bool = false) async {
        loadState = .loading
        let env = env
        let existing = importURLs
        let widths = await Task.detached { existing.compactMapValues { env.pixelWidth($0) } }.value
        pixelWidths.merge(widths) { _, new in new }
        bannerFile = env.banner(titleID)
        let result = await env.media(titleID, retrying)
        guard !closed, !Task.isCancelled else { return }
        switch result {
        case .offline: media = nil; loadState = .offline
        case .none: media = nil; loadState = .none
        case .loaded(let found):
            media = found
            loadState = .loaded
            for source in found.screenshots.indices.map({ ArtworkChoice.Source.screenshot($0) }) {
                if let file = env.cachedCandidate(source, titleID) { downloaded[source] = file; continue }
                do {
                    let file = try await env.candidate(source, titleID)
                    guard !closed, !Task.isCancelled else { return }
                    downloaded[source] = file
                } catch {
                    guard !closed, !Task.isCancelled else { return }
                    failed.insert(source)
                }
            }
        }
        if cursor == nil { cursor = tiles.firstIndex { $0.isSelected } }
    }


    /// Copies a chosen file into the game's folder (ArtworkImport, off the main thread) and chooses it for the slot. A file that is
    /// not an image is an error to show, a small one a warning: both leave the choice as it was.
    func importFile(_ url: URL) async {
        let env = env, directory = importDirectory, kind = importKind, target = slot   // the tab may change while the file is prepared
        let result = await Task.detached { Result { try env.prepare(url, kind, directory) } }.value
        switch result {
        case .success(let prepared):
            let name = prepared.url.lastPathComponent
            guard !closed else {   // the panel closed meanwhile: a copy that nothing uses is not kept
                if !original.importedFiles.contains(name) { env.removeFile(prepared.url) }
                return
            }
            if !importedFiles.contains(name) { importedFiles.append(name) }
            importURLs[name] = prepared.url
            let width = Int(prepared.pixelSize.width)
            pixelWidths[name] = width
            sessionImports.insert(name)
            choose(.imported(name), for: target)
            if prepared.lowResolution { notice = .warning(String(format: labels("artwork.lowResWarning"), width)) }
        case .failure(let error):
            guard !closed else { return }
            notice = .error((error as? ArtworkImport.Failure).map { labels($0.messageKey) } ?? error.localizedDescription)
        }
    }


    /// Writes the draft to the library, which also removes the copies no slot uses any more. When the library cannot be written,
    /// nothing is removed and the panel stays as it was, with an error, so Save can be pressed again.
    @discardableResult func save(to library: GameLibrary) -> Bool {
        guard isDirty else { return false }
        guard library.setArtwork(draft, for: gameID) else { notice = .error(labels("artwork.saveFailed")); return false }
        closed = true
        loadTask?.cancel()
        original = draft
        return true
    }

    /// Leaves the library as it was. A copy made while the panel was open that the saved artwork does not use is removed.
    func cancel() {
        closed = true
        loadTask?.cancel()
        for name in sessionImports where !original.importedFiles.contains(name) {
            if let url = importURLs[name] { env.removeFile(url) }
        }
        sessionImports = []
    }
}
