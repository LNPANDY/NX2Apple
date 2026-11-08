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
    public private(set) var input = ShellInputLog()
    /// A short message the host view shows as an alert.
    public var notice: String?
    /// The log the host view shows in a read-only sheet.
    public var log: LogPresentation?
    /// Play is preparing the game's resources or handing over to the engine.
    public private(set) var launchingGame = false

    public private(set) var globalPadMap = PadMap()
    /// The last controller state, sent only while the button test is open.
    public private(set) var padSnapshot: PadSnapshot?

    @ObservationIgnored private let config: ShellHostConfig
    @ObservationIgnored private let launcher: any GameLauncher
    @ObservationIgnored private let picker: any FolderPicker
    @ObservationIgnored private let adapter = GamepadAdapter()
    @ObservationIgnored private var dataStores: [String: BookmarkStore] = [:]
    @ObservationIgnored private var cloudStores: [String: BookmarkStore] = [:]
    @ObservationIgnored private var artwork: [URL: Artwork] = [:]
    /// The shell-level settings every game falls back to (game > shell > built-in).
    @ObservationIgnored public let shellSettings: ShellSettingsStore
    @ObservationIgnored private let shellData: BookmarkStore
    @ObservationIgnored private let shellCloud: BookmarkStore
    @ObservationIgnored private var shellChoices: [String]
    /// The shell data folder the games were matched in by identity, each game's matched folder by title ID, and the scan in flight.
    @ObservationIgnored private var scannedShellFolder: String?
    @ObservationIgnored private var shellMatches: [String: URL] = [:]
    @ObservationIgnored private var shellScan: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var defaultsObserver: (any NSObjectProtocol)?

    public init(config: ShellHostConfig, launcher: any GameLauncher = StubGameLauncher(), picker: any FolderPicker = NoFolderPicker(),
                shellSettings: ShellSettingsStore = .current) {
        self.config = config
        self.launcher = launcher
        self.picker = picker
        self.shellSettings = shellSettings
        shellData = BookmarkStore(defaults: shellSettings.defaults, key: ShellSettingsStore.dataFolderKey)
        shellCloud = BookmarkStore(defaults: shellSettings.defaults, key: ShellSettingsStore.cloudSavesKey)
        shellChoices = Self.choices(of: shellSettings)
        globalPadMap = shellSettings.padMap
        // Game files stay out of the iCloud backup (#618), also what an earlier version put there. Off the main actor, it lists folders.
        let dataRoot = config.appDataRoot
        Task.detached(priority: .utility) { BackupExclusion.apply(appDataRoot: dataRoot) }
        reload()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsDidChange() }
        }
    }

    deinit { defaultsObserver.map(NotificationCenter.default.removeObserver) }

    /// Shell choices that change the displayed game defaults.
    private static func choices(of settings: ShellSettingsStore) -> [String] {
        [settings.gameDefaults.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), settings.padMap.envValue ?? ""]
    }

    /// Rebuilds the details in place after a shell folder, overlay or controller mapping changes.
    public func refreshAll() {
        globalPadMap = shellSettings.padMap
        shellChoices = Self.choices(of: shellSettings)
        startShellScan()
        details = entries.map(detail(for:))
    }

    /// Looks for every game's image by identity in the shell data folder. The drive is read off the main actor: until the scan is
    /// done the games show what the by-name paths give (usually "Needs game data"), then the details are built again. A new
    /// folder starts a new scan and drops the old matches, the same folder keeps its matches unless `force`.
    private func startShellScan(force: Bool = false) {
        guard case .url(let folder) = shellData.resolve() else {
            shellScan?.cancel(); scannedShellFolder = nil; shellMatches = [:]; return
        }
        if !force && scannedShellFolder == folder.path { return }
        shellScan?.cancel()
        scannedShellFolder = folder.path
        shellMatches = [:]
        let wanted = entries.compactMap { e in
            e.problem == nil ? e.manifest.flatMap { m in RomfsIdentity.parse(m.romfsIdentity).map { (m.titleID, $0) } } : nil
        }
        guard !wanted.isEmpty else { return }
        // `shellData.resolve()` above opened the bookmark's security scope and `BookmarkStore` keeps it open while this folder is
        // chosen (until another is stored or it is cleared), so the detached scan and its header reads run inside it.
        shellScan = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [String: URL] in
                let index = ShellDataIndex(folder: folder)
                var found: [String: URL] = [:]
                for (titleID, identity) in wanted where !Task.isCancelled { if let dir = index.folder(matching: identity) { found[titleID] = dir } }
                return found
            }.value
            guard let self, !Task.isCancelled, self.scannedShellFolder == folder.path else { return }
            self.shellMatches = found
            if !found.isEmpty { self.details = self.entries.map(self.detail(for:)) }
        }
    }

    /// For tests: returns when the scan of the shell data folder is done.
    func waitForShellScan() async { await shellScan?.value }

    private func defaultsDidChange() {
        if Self.choices(of: shellSettings) != shellChoices { refreshAll() }
    }

    // MARK: Catalogue

    /// Reads the games folder again and sorts the library (see `LibraryOrder`). Only this and the first load re-sort:
    /// a change to one game updates it in place.
    public func reload() {
        let scanned = GameCatalogue.scan(root: config.gamesRoot).filter { !isDeleted($0) }
        let built = scanned.map(detail(for:))
        let order = LibraryOrder.ids(of: built.map(\.game), lastPlayed: Dictionary(uniqueKeysWithValues: scanned.compactMap { e in
            lastPlayed(e.id).map { (e.id, $0) } }))
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        entries = scanned.sorted { position[$0.id] ?? 0 < position[$1.id] ?? 0 }
        details = built.sorted { position[$0.id] ?? 0 < position[$1.id] ?? 0 }
        startShellScan(force: true)
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

    private enum CloudSaves { case off, own(URL), stale, shell(URL), none }

    /// Where the game's cloud saves go: off when the player turned them off for the game, then the game's own folder,
    /// then the shell settings' folder.
    private func cloudSaves(_ id: String) -> CloudSaves {
        if config.defaults(id).bool(forKey: GameDefaults.cloudSavesOffKey) { return .off }
        switch cloudStore(id).resolve() {
        case .url(let url): return .own(url)
        case .stale: return .stale
        case .none:
            if case .url(let url) = shellCloud.resolve() { return .shell(url) }
            return .none
        }
    }

    private func data(for entry: CatalogueEntry) -> DataResolution {
        guard let manifest = entry.manifest, entry.problem == nil else { return .missing }
        return DataLocator.locate(manifest: manifest, picked: dataStore(entry.id).resolve(), appFolder: appFolder(for: entry.id),
                                  global: shellData.resolve(), shellMatch: shellMatches[manifest.titleID])
    }

    private func profile(for entry: CatalogueEntry, data: DataResolution? = nil) -> LauncherProfile? {
        guard let base = entry.profile, entry.problem == nil else { return nil }
        // A DM_LANG row of the game's own list stays, except the all-languages row of a game with no language list (the engine's
        // fallback): the RomFS names the languages it really has (#668)
        if let row = base.settings.first(where: { $0.env == "DM_LANG" }), !RomfsLanguages.isFallbackRow(row) { return base }
        guard let url = (data ?? self.data(for: entry)).url else { return base }
        return RomfsLanguages.applying(to: base, options: RomfsLanguages.options(in: url))   // read once per image: RomfsLanguages caches by size and date
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
                            recentlyPlayed: played.map { ShellFormat.played($0, now: config.now()) }, version: entry.manifest?.displayVersion ?? "")
        guard let profile = profile(for: entry, data: data) else {
            return GameDetail(game: tile, dataNote: dataNote(data, found: false))
        }
        let store = GameSettingsStore(profile: profile, defaults: config.defaults(entry.id), shell: shellSettings.gameDefaults)
        var cloud: String?
        var cloudNote = ""
        var cloudFromShell = false
        switch cloudSaves(entry.id) {
        case .own(let url): cloud = url.lastPathComponent
        case .stale: cloudNote = hostText("The folder you chose before is no longer readable. Please choose it again.")
        case .shell(let url): cloud = hostText("\(url.lastPathComponent) (from Settings)"); cloudFromShell = true
        case .off, .none: break
        }
        var shellFolder = false
        if case .url = shellCloud.resolve() { shellFolder = true }
        let fromShell = Set(profile.settings.filter(store.isFromShell).map(\.env))
        let pad = GamePadMapStore(defaults: config.defaults(entry.id))
        let sections = SettingsPresenter.sections(profile: profile, values: store.values(), fromShell: fromShell)
        // A profile-provided DM_PAD_MAP row owns the mapping, so do not offer conflicting shell overrides.
        let padSections = profile.settings.contains { $0.env == "DM_PAD_MAP" } ? [] : [pad.section()]
        return GameDetail(
            game: tile, sections: sections + padSections,
            dataSource: dataSource(data), dataNote: dataNote(data, found: data.found),
            cloudSaves: cloud, cloudNote: cloudNote, dlc: dlc(data), hasModifiedSettings: store.hasModifiedSettings || !pad.entries.isEmpty,
            dataFromShell: data.source == .shell, cloudFromShell: cloudFromShell,
            cloudCanUseShell: shellFolder && !cloudFromShell)
    }

    private func dataSource(_ data: DataResolution) -> String {
        switch data.source {
        case .app: hostText("This app's folder")
        case .picked: data.url?.lastPathComponent ?? ""
        case .shell: hostText("\(data.url?.lastPathComponent ?? "") (from Settings)")
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
            onAppUpdate: { [weak self] in self?.appUpdate() },
            onPickShellData: { [weak self] in self.map { model in Task { await model.pickShellDataNow() } } },
            onPickShellCloud: { [weak self] in self.map { model in Task { await model.pickShellCloudNow() } } },
            onUseShellCloud: { [weak self] id in self?.useShellCloudSaves(id) },
            onClearShellData: { [weak self] in self?.clearShellData() },
            onClearShellCloud: { [weak self] in self?.clearShellCloud() },
            onGlobalPadMapChange: { [weak self] setting, value in
                guard let self else { return }
                if setting == "swapAB" { self.shellSettings.setPadSwapAB(value == "1") }
                else { self.shellSettings.setPadButton(setting, to: value) }
                self.refreshAll()
            },
            onGlobalPadMapReset: { [weak self] in self?.shellSettings.resetPadMap(); self?.refreshAll() },
            onButtonTest: { [weak self] open in self?.buttonTest(open) },
            onDeleteGame: { [weak self] id, saves in self?.deleteGame(id, saves: saves) })
    }

    public func change(_ id: String, setting: String, value: String) {
        guard let entry = entry(id), let profile = profile(for: entry) else { return }
        if setting.hasPrefix("pad.") {
            GamePadMapStore(defaults: config.defaults(id)).change(setting, value: value)
        } else {
            GameSettingsStore(profile: profile, defaults: config.defaults(id), shell: shellSettings.gameDefaults).set(setting, to: value)
        }
        refresh(id)
    }

    public func resetDefaults(_ id: String) {
        guard let entry = entry(id), let profile = profile(for: entry) else { return }
        GameSettingsStore(profile: profile, defaults: config.defaults(id)).reset()
        GamePadMapStore(defaults: config.defaults(id)).reset()
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
        if cloudStore(id).store(url) { config.defaults(id).removeObject(forKey: GameDefaults.cloudSavesOffKey) }
        else { notice = hostText("That folder could not be remembered. Try a different one.") }
        refresh(id)
    }

    func pickShellDataNow() async {
        guard let url = await picker.pickFolder() else { return }
        guard shellData.store(url) else { notice = hostText("That folder could not be remembered. Try a different one."); return }
        shellSettings.storeDataFolderName(url.lastPathComponent)
        refreshAll()
    }

    func pickShellCloudNow() async {
        guard let url = await picker.pickFolder() else { return }
        guard shellCloud.store(url) else { notice = hostText("That folder could not be remembered. Try a different one."); return }
        shellSettings.storeCloudSavesFolderName(url.lastPathComponent)
        refreshAll()
    }

    public func disableCloudSaves(_ id: String) {
        cloudStore(id).clear()
        config.defaults(id).set(true, forKey: GameDefaults.cloudSavesOffKey)
        refresh(id)
    }

    /// The game follows the shell settings' cloud-saves folder again.
    public func useShellCloudSaves(_ id: String) {
        cloudStore(id).clear()
        config.defaults(id).removeObject(forKey: GameDefaults.cloudSavesOffKey)
        refresh(id)
    }

    func clearShellData() {
        shellData.clear()
        shellSettings.clearDataFolderName()
        refreshAll()
    }

    func clearShellCloud() {
        shellCloud.clear()
        shellSettings.clearCloudSavesFolderName()
        refreshAll()
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

    // MARK: Delete

    /// Deletes the game's folder in this app (its saves only when `saves`), forgets the folder the player picked for its data
    /// (that folder is the player's and is not touched) and when it was played, and takes the game off the list. The game's
    /// framework inside the app stays: see `GameDeletion`.
    public func deleteGame(_ id: String, saves: Bool) {
        guard let entry = entry(id) else { return }
        let failed = GameDeletion.delete(in: appFolder(for: id), saves: saves)
        dataStore(id).clear()
        let defaults = config.defaults(id)
        defaults.removeObject(forKey: LastPlayedStore.key)
        defaults.set(GameDeletion.stamp(entry), forKey: GameDeletion.deletedKey)
        reload()
        if !failed.isEmpty { notice = hostText("Some files of \(entry.title) could not be deleted.") }
    }

    /// Deleted, and still the same build with no game data in its folder. A new build or game data in the folder brings the
    /// game back, and the mark is dropped.
    private func isDeleted(_ entry: CatalogueEntry) -> Bool {
        let defaults = config.defaults(entry.id)
        guard let deleted = defaults.string(forKey: GameDeletion.deletedKey) else { return false }
        let hasData = entry.manifest.map { DataLocator.holder(of: appFolder(for: entry.id), manifest: $0, .default) != nil } ?? false
        if deleted == GameDeletion.stamp(entry) && !hasData { return true }
        defaults.removeObject(forKey: GameDeletion.deletedKey)
        return false
    }

    public func appUpdate() {
        guard let url = config.updateURL else { notice = hostText("No update address is set up for this app."); return }
        config.openURL(url)
    }

    public func play(_ id: String) {
        Task { await playNow(id) }
    }

    func playNow(_ id: String) async {
        guard !launchingGame, let entry = entry(id), let manifest = entry.manifest, let framework = entry.frameworkURL,
              details.first(where: { $0.id == id })?.game.state == .playable,
              case let resolved = data(for: entry), let dataURL = resolved.url,
              let profile = profile(for: entry, data: resolved) else { return }
        launchingGame = true
        defer { launchingGame = false }
        var cloud: URL?
        switch cloudSaves(id) {
        case .own(let url), .shell(let url): cloud = url
        case .off, .stale, .none: break
        }
        // Remembered when Play is triggered, even if the launcher then fails (the stub). The order changes at the next load.
        LastPlayedStore(defaults: config.defaults(id)).record(config.now())
        refresh(id)
        var game = LaunchableGame(
            titleID: id, name: entry.title, manifest: manifest, directory: entry.directory, frameworkURL: framework, dataURL: dataURL,
            appFolder: appFolder(for: id), environment: launchEnvironment(profile: profile, id: id), cloudSavesURL: cloud)
        do {
            game.shaderResourcesURL = try await ShaderResources.shared.prepare(game)
            try await launcher.launch(game)
        } catch { notice = error.localizedDescription }
    }

    /// The right-stick hint's words: a few, no semicolon, short enough for the right third of a small phone.
    static var touchHint: String { hostText("Right stick: drag here") }

    /// DM_HOME_QUIT_TEXT: the game's quit prompt in the player's language, one text per line in the engine's order (home_quit.h): the hold
    /// indicator, the title with the game's name, the note, Quit and Cancel. The engine draws it when Quit is picked in the in-game menu (the gear)
    /// or Home is held. The menu item reads the title without its question mark.
    static func quitPromptText(gameName: String) -> String {
        [hostText("Keep holding to quit"), hostText("Quit \(gameName)?"),
         hostText("Unsaved progress will be lost. The app closes. Open it again to get back to your games."), hostText("Quit"), hostText("Cancel")]
            .map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    /// A game's values for the engine: its own choices, then the shell's defaults. A game whose settings list has no
    /// performance overlay row still gets the shell's choice.
    func launchEnvironment(profile: LauncherProfile, id: String) -> [String: String] {
        var env = GameSettingsStore(profile: profile, defaults: config.defaults(id), shell: shellSettings.gameDefaults).values()
        for (key, value) in shellSettings.gameDefaults where env[key] == nil { env[key] = value }
        // The words the engine shows once per launch where the 3D layout's undrawn right stick is (patch 0067), in the player's language.
        env["DM_TOUCH_HINT"] = Self.touchHint
        // The quit prompt's words (patch 0068), as the Mac launcher passes them for its Home button prompt.
        env["DM_HOME_QUIT_TEXT"] = Self.quitPromptText(gameName: entry(id)?.title ?? id)
        // A launcher.json DM_PAD_MAP row is authoritative, including an empty value.
        if !profile.settings.contains(where: { $0.env == "DM_PAD_MAP" }) {
            env["DM_PAD_MAP"] = PadMap.merged(global: shellSettings.padMap,
                                            game: GamePadMapStore(defaults: config.defaults(id)).entries).envValue
        }
        return env
    }

    // MARK: Controllers

    /// Starts reading GameController: the connected controllers become `controllers`, their buttons `input`.
    public func startControllers() {
        adapter.onInput = { [weak self] action, device in
            guard let self, !self.launchingGame else { return }
            self.input.append(action, device: device)
        }
        // Releases go on while a game launches: a button pressed before it still comes up for the echo window.
        adapter.onRelease = { [weak self] action, device in self?.input.append(action, device: device, released: true) }
        adapter.onControllersChange = { [weak self] connected in
            self?.controllers = connected.map(Self.info(for:))
        }
        adapter.start()
    }

    public func stopControllers() { adapter.stop() }

    /// The button test opened or closed: the adapter reports every controller state in between.
    public func buttonTest(_ open: Bool) {
        adapter.onSnapshot = open ? { [weak self] in self?.padSnapshot = $0 } : nil
        if !open { padSnapshot = nil }
    }

    static func info(for c: ConnectedController) -> ControllerInfo {
        ControllerInfo(id: c.id, name: c.name, player: hostText("Player \(c.player)"), batteryPercent: c.batteryPercent, charging: c.charging)
    }
}
