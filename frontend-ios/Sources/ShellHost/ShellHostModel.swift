import Foundation
import Observation
import ShellControllers
import ShellUI
#if canImport(UIKit)
import UIKit
#endif

/// Where the host finds things. Everything the model touches outside itself is here, so tests point it at a temporary folder.
public struct ShellHostConfig: Sendable {
    /// `Games/`: one `<title ID>/` bundle folder per game.
    public var gamesRoot: URL
    /// The app's `Documents/games/`: `<title ID>/` holds a game's data, save, temp and log.txt (patch 0003's layout).
    public var appDataRoot: URL
    public var environment: HostEnvironment
    /// Opened by "Update app". Nil: the shell says no address is configured.
    public var updateURL: URL?
    public var defaults: @Sendable (String) -> UserDefaults
    public var openURL: @MainActor @Sendable (URL) -> Void
    /// The clock, for the last-played date and its wording.
    public var now: @Sendable () -> Date

    public init(gamesRoot: URL, appDataRoot: URL, environment: HostEnvironment = HostEnvironment(), updateURL: URL? = nil,
                defaults: @escaping @Sendable (String) -> UserDefaults = GameDefaults.suite(for:),
                openURL: @escaping @MainActor @Sendable (URL) -> Void = ShellHostConfig.systemOpen,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.gamesRoot = gamesRoot
        self.appDataRoot = appDataRoot
        self.environment = environment
        self.updateURL = updateURL
        self.defaults = defaults
        self.openURL = openURL
        self.now = now
    }

    @MainActor public static func systemOpen(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// The app's `Documents/games/`.
    public static func defaultAppDataRoot() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("games", isDirectory: true)
    }
}

/// The host behind the views: turns the catalogue, the saved settings, the picked folders and the controllers into
/// `GameDetail` values, and acts on `ShellActions`. `ShellUI` stays view-only, every file is read here.
@MainActor @Observable public final class ShellHostModel {
    public private(set) var details: [GameDetail] = []
    public private(set) var entries: [CatalogueEntry] = []
    public private(set) var controllers: [ControllerInfo] = []
    public private(set) var input: ShellInput?
    /// A short message the host view shows as an alert.
    public var notice: String?
    /// The log the host view shows in a read-only sheet.
    public var log: LogPresentation?

    @ObservationIgnored private let config: ShellHostConfig
    @ObservationIgnored private let launcher: any GameLauncher
    @ObservationIgnored private let picker: any FolderPicker
    @ObservationIgnored private let adapter = GamepadAdapter()
    @ObservationIgnored private var dataStores: [String: BookmarkStore] = [:]
    @ObservationIgnored private var cloudStores: [String: BookmarkStore] = [:]
    @ObservationIgnored private var artwork: [URL: Artwork] = [:]

    public init(config: ShellHostConfig, launcher: any GameLauncher = StubGameLauncher(), picker: any FolderPicker = NoFolderPicker()) {
        self.config = config
        self.launcher = launcher
        self.picker = picker
        reload()
    }

    // MARK: Catalogue

    /// Reads the games folder again and sorts the library (see `LibraryOrder`). Only this and the first load re-sort:
    /// a change to one game updates it in place.
    public func reload() {
        let scanned = GameCatalogue.scan(root: config.gamesRoot)
        let built = scanned.map(detail(for:))
        let order = LibraryOrder.ids(of: built.map(\.game), lastPlayed: Dictionary(uniqueKeysWithValues: scanned.compactMap { e in
            lastPlayed(e.id).map { (e.id, $0) } }))
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        entries = scanned.sorted { position[$0.id] ?? 0 < position[$1.id] ?? 0 }
        details = built.sorted { position[$0.id] ?? 0 < position[$1.id] ?? 0 }
    }

    private func lastPlayed(_ id: String) -> Date? { LastPlayedStore(defaults: config.defaults(id)).date }

    private func refresh(_ id: String) {
        guard let e = entries.firstIndex(where: { $0.id == id }), let d = details.firstIndex(where: { $0.id == id }) else { return }
        details[d] = detail(for: entries[e])
    }

    private func entry(_ id: String) -> CatalogueEntry? { entries.first { $0.id == id } }

    public func appFolder(for id: String) -> URL { config.appDataRoot.appendingPathComponent(id, isDirectory: true) }

    private func dataStore(_ id: String) -> BookmarkStore {
        if let s = dataStores[id] { return s }
        let s = BookmarkStore(defaults: config.defaults(id), key: BookmarkStore.gameDataKey)
        dataStores[id] = s
        return s
    }

    private func cloudStore(_ id: String) -> BookmarkStore {
        if let s = cloudStores[id] { return s }
        let s = BookmarkStore(defaults: config.defaults(id), key: BookmarkStore.cloudSavesKey)
        cloudStores[id] = s
        return s
    }

    /// The shell-level settings every game falls back to (ShellSettingsStore: game > shell > built-in).
    public private(set) var shellSettings = ShellSettingsStore()

    /// The shell-level data folder as a bookmark resolution, for the locator's global source.
    private func globalData() -> BookmarkResolution {
        guard let data = shellSettings.dataBookmark else { return .none }
        // BookmarkStore reads through UserDefaults; a volatile in-memory store carrying just the global bookmark
        // keeps that contract. The resolution is cheap, so no caching is needed.
        let name = "shell-global-data"
        UserDefaults().removePersistentDomain(forName: name)   // start clean every call
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.set(data, forKey: BookmarkStore.gameDataKey)
        let resolution = BookmarkStore(defaults: suite, key: BookmarkStore.gameDataKey).resolve()
        UserDefaults().removePersistentDomain(forName: name)
        return resolution
    }

    private func data(for entry: CatalogueEntry) -> DataResolution {
        guard let manifest = entry.manifest, entry.problem == nil else { return .missing }
        return DataLocator.locate(manifest: manifest, picked: dataStore(entry.id).resolve(), appFolder: appFolder(for: entry.id),
                                  global: globalData())
    }

    private func image(_ url: URL?) -> Artwork? {
        guard let url else { return nil }
        if let a = artwork[url] { return a }
        guard let bytes = try? Data(contentsOf: url), let a = Artwork(id: url.path, data: bytes) else { return nil }
        artwork[url] = a
        return a
    }

    private func detail(for entry: CatalogueEntry) -> GameDetail {
        let data = data(for: entry)
        let state = GameStateResolver.state(for: entry, data: data, environment: config.environment)
        let played = lastPlayed(entry.id)
        let tile = GameTile(id: entry.id, title: entry.title, subtitle: entry.manifest.map { ShellFormat.version($0.displayVersion) } ?? "",
                            banner: image(entry.bannerURL), icon: image(entry.iconURL), state: state,
                            recentlyPlayed: played.map { ShellFormat.played($0, now: config.now()) })
        guard let profile = entry.profile, entry.problem == nil else {
            return GameDetail(game: tile, dataNote: dataNote(data, found: false))
        }
        let store = GameSettingsStore(profile: profile, defaults: config.defaults(entry.id))
        var cloud: String?
        var cloudNote = ""
        switch cloudStore(entry.id).resolve() {
        case .url(let url): cloud = url.lastPathComponent
        case .stale: cloudNote = hostText("The folder you chose before is no longer readable. Please choose it again.")
        case .none: break
        }
        return GameDetail(
            game: tile, sections: SettingsPresenter.sections(profile: profile, values: store.values()),
            dataSource: dataSource(data), dataNote: dataNote(data, found: data.found),
            cloudSaves: cloud, cloudNote: cloudNote, dlc: dlc(data), hasModifiedSettings: store.hasModifiedSettings)
    }

    private func dataSource(_ data: DataResolution) -> String {
        switch data.source {
        case .app: hostText("This app's folder")
        case .picked: data.url?.lastPathComponent ?? ""
        case nil: ""
        }
    }

    private func dataNote(_ data: DataResolution, found: Bool) -> String {
        if data.pickedIsStale && !found { return hostText("The location you picked before is no longer readable (the app was signed differently). Please choose it again.") }
        return found ? "" : hostText("Choose a RomFS folder or romfs.img on this device, an external drive, or iCloud Drive.")
    }

    private func dlc(_ data: DataResolution) -> String {
        guard let url = data.url else { return hostText("No additional content") }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("aoc").path))?.filter { !$0.hasPrefix(".") } ?? []
        switch names.count {
        case 0: return hostText("No additional content")
        case 1: return hostText("1 additional content pack")
        default: return hostText("\(names.count) additional content packs")
        }
    }

    // MARK: Actions

    /// The closures for `LibraryView`.
    public var actions: ShellActions {
        ShellActions(
            onPlay: { [weak self] id in self?.play(id) },
            onChange: { [weak self] id, setting, value in self?.change(id, setting: setting, value: value) },
            onPickGameData: { [weak self] id in self?.pickGameData(id) },
            onUseAppData: { [weak self] id in self?.useAppData(id) },
            onPickCloudSaves: { [weak self] id in self?.pickCloudSaves(id) },
            onDisableCloudSaves: { [weak self] id in self?.disableCloudSaves(id) },
            onResetDefaults: { [weak self] id in self?.resetDefaults(id) },
            onShowLog: { [weak self] id in self?.showLog(id) },
            onAppUpdate: { [weak self] in self?.appUpdate() })
    }

    public func change(_ id: String, setting: String, value: String) {
        guard let profile = entry(id)?.profile else { return }
        GameSettingsStore(profile: profile, defaults: config.defaults(id)).set(setting, to: value)
        refresh(id)
    }

    public func resetDefaults(_ id: String) {
        guard let profile = entry(id)?.profile else { return }
        GameSettingsStore(profile: profile, defaults: config.defaults(id)).reset()
        refresh(id)
    }

    public func pickGameData(_ id: String) {
        Task { await pickGameDataNow(id) }
    }

    func pickGameDataNow(_ id: String) async {
        guard let url = await picker.pickFolder() else { return }
        guard dataStore(id).store(url) else {
            notice = hostText("That location could not be remembered. Try a different one.")
            return
        }
        refresh(id)
        if let game = details.first(where: { $0.id == id })?.game, game.state == .needsGameData {
            notice = hostText("No game data for \(game.title) was found in that folder.")
        }
    }

    public func useAppData(_ id: String) {
        dataStore(id).clear()
        refresh(id)
        if details.first(where: { $0.id == id })?.game.state == .needsGameData {
            notice = hostText("This app's folder has no data for this game yet. Copy it to games/\(id) in this app's folder in Files.")
        }
    }

    public func pickCloudSaves(_ id: String) {
        Task { await pickCloudSavesNow(id) }
    }

    func pickCloudSavesNow(_ id: String) async {
        guard let url = await picker.pickFolder() else { return }
        if !cloudStore(id).store(url) { notice = hostText("That folder could not be remembered. Try a different one.") }
        refresh(id)
    }

    public func disableCloudSaves(_ id: String) {
        cloudStore(id).clear()
        refresh(id)
    }

    public func showLog(_ id: String) {
        guard let entry = entry(id) else { return }
        let app = appFolder(for: id)
        let folders = [data(for: entry).url, app].compactMap { $0 }
        // The shell's engine writes Documents/log.txt (EngineLaunchPlan) for whichever game ran last, so it counts only when that run was this game's
        let engine = config.appDataRoot.deletingLastPathComponent().appendingPathComponent("log.txt")
        let found = folders.lazy.compactMap { LogReader.read($0.appendingPathComponent("log.txt")) }.first
            ?? (LogReader.isRun(of: id, engine) ? LogReader.read(engine) : nil)
        log = LogPresentation(gameID: id, title: entry.title, text: found?.text, truncated: found?.truncated ?? false)
    }

    public func appUpdate() {
        guard let url = config.updateURL else { notice = hostText("No update address is set up for this app."); return }
        config.openURL(url)
    }

    public func play(_ id: String) {
        Task { await playNow(id) }
    }

    func playNow(_ id: String) async {
        guard let entry = entry(id), let manifest = entry.manifest, let profile = entry.profile, let framework = entry.frameworkURL,
              details.first(where: { $0.id == id })?.game.state == .playable, let dataURL = data(for: entry).url else { return }
        var cloud: URL?
        if case .url(let url) = cloudStore(id).resolve() { cloud = url }
        // Remembered when Play is triggered, even if the launcher then fails (the stub). The order changes at the next load.
        LastPlayedStore(defaults: config.defaults(id)).record(config.now())
        refresh(id)
        let game = LaunchableGame(
            titleID: id, name: entry.title, manifest: manifest, directory: entry.directory, frameworkURL: framework, dataURL: dataURL,
            appFolder: appFolder(for: id), environment: GameSettingsStore(profile: profile, defaults: config.defaults(id)).values(), cloudSavesURL: cloud)
        do { try await launcher.launch(game) }
        catch { notice = error.localizedDescription }
    }

    // MARK: Controllers

    /// Starts reading GameController: the connected controllers become `controllers`, their buttons `input`.
    public func startControllers() {
        adapter.onInput = { [weak self] action, device in
            guard let self else { return }
            self.input = ShellInput(sequence: (self.input?.sequence ?? 0) + 1, action: action, device: device)
        }
        adapter.onControllersChange = { [weak self] connected in
            self?.controllers = connected.map(Self.info(for:))
        }
        adapter.start()
    }

    public func stopControllers() { adapter.stop() }

    static func info(for c: ConnectedController) -> ControllerInfo {
        ControllerInfo(id: c.id, name: c.name, player: hostText("Player \(c.player)"), batteryPercent: c.batteryPercent, charging: c.charging)
    }
}
