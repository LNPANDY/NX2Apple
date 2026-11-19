import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Translucent-fade parameters for unbuilt or unavailable artwork:
/// 48% saturation + 50% artwork opacity blending into surface + 52% muted title at rest, restoring 100% full color when active.
enum LibraryArtworkTone {
    static let mutedSaturation: Double = 0.48
    static let mutedArtworkOpacity: Double = 0.50
    static let mutedTitleOpacity: Double = 0.52

    static func saturation(muted: Bool, active: Bool = false) -> Double {
        muted && !active ? mutedSaturation : 1.0
    }

    static func artworkOpacity(muted: Bool, active: Bool = false) -> Double {
        muted && !active ? mutedArtworkOpacity : 1.0
    }

    static func titleOpacity(muted: Bool, active: Bool = false) -> Double {
        muted && !active ? mutedTitleOpacity : 1.0
    }
}

/// Thread-safe per-game snapshot cache preventing synchronous Info.plist and stat probes on every SwiftUI body redraw.
final class LibraryArtworkStateCache {
    private struct Key: Equatable {
        let appPath: String
        let ipaPath: String
        let iosAppPath: String
        let installedDevice: String
        let hasShellFramework: Bool
        let installedViaShellReceipt: Bool
        let shellIPAExists: Bool
        let baseInputs: [String]
        let folderInputs: [String]
        let sourceFolder: String
        let titleID: String
        let building: Bool

        init(_ game: LibraryGame, building: Bool) {
            appPath = game.appPath
            ipaPath = game.ipaPath
            iosAppPath = game.iosAppPath
            installedDevice = game.installedDevice
            hasShellFramework = game.hasShellFramework
            installedViaShellReceipt = game.installedViaShellReceipt
            shellIPAExists = game.shellIPAExists
            baseInputs = game.inputs["base"] ?? []
            folderInputs = game.inputs[GameLibrary.folderInput] ?? []
            sourceFolder = game.sourceFolder
            titleID = game.titleID
            self.building = building
        }
    }

    private let lock = NSLock()
    private var entries: [UUID: (key: Key, state: LibraryArtworkState)] = [:]

    func state(for game: LibraryGame, building: Bool = false) -> LibraryArtworkState {
        let key = Key(game, building: building)
        lock.lock()
        if let cached = entries[game.id], cached.key == key {
            lock.unlock()
            return cached.state
        }
        lock.unlock()
        let computed = LibraryArtworkState(game, building: building)
        lock.lock()
        entries[game.id] = (key, computed)
        lock.unlock()
        return computed
    }

    func states(for games: [LibraryGame], buildingID: UUID?) -> [UUID: LibraryArtworkState] {
        Dictionary(uniqueKeysWithValues: games.map { ($0.id, state(for: $0, building: buildingID == $0.id)) })
    }

    func invalidate(id: UUID? = nil) {
        lock.lock()
        if let id { entries.removeValue(forKey: id) }
        else { entries.removeAll(keepingCapacity: true) }
        lock.unlock()
    }
}

/// Only desktop-observable availability. An iOS artifact does not prove installation on a device.
struct LibraryArtworkState: Equatable {
    enum Attention: Equatable { case none, notBuilt, missingData, fixFiles, building }
    let mac: Bool
    let ios: Bool
    let attention: Attention
    var monochrome: Bool { attention != .none }
    var chipKey: String? {
        switch attention {
        case .notBuilt: return "library.chip.notBuilt"
        case .missingData: return "ios.ui.missingDataChip"
        case .fixFiles: return "ios.ui.fixGameFilesChip"
        case .building: return "library.building"
        case .none: return mac && ios ? "library.chip.both" : (ios ? "library.chip.iosOnly" : nil)
        }
    }
    var symbol: String? {
        guard attention == .none else { return nil }
        return mac && ios ? "laptopcomputer.and.iphone" : "iphone"
    }
    var color: Color {
        if attention == .none { return .white.opacity(0.9) }
        if attention == .building { return Color(red: 1, green: 0.94, blue: 0.84) }
        return Color(red: 1, green: 0.78, blue: 0.24)
    }
    init(mac: Bool, ios: Bool, attention: Attention) {
        self.mac = mac
        self.ios = ios
        self.attention = attention
    }
    init(_ game: LibraryGame, building: Bool = false, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        var missingMacData = false
        if game.appPath.isEmpty { mac = false }
        else {
            do { mac = try MacGameBundle.read(URL(fileURLWithPath: game.appPath)).titleID == game.titleID }
            catch MacGameBundle.Invalid.missingData { mac = false; missingMacData = true }
            catch { mac = false }
        }
        ios = game.hasIOSBuild
        if mac { attention = .none }
        else if building { attention = .building }
        else if missingMacData { attention = .missingData }
        else if !game.appPath.isEmpty {
            attention = !exists(game.appPath) || GameLibrary.onUnmountedVolume(game.appPath) ? .missingData : .fixFiles
        } else if ios { attention = .none }
        else if let base = game.inputs["base"]?.first, !base.isEmpty {
            attention = exists(base) ? .notBuilt : .missingData
        } else if let folder = game.inputs[GameLibrary.folderInput]?.first ?? (game.sourceFolder.isEmpty ? nil : game.sourceFolder) {
            attention = exists(folder) ? .notBuilt : .missingData
        } else { attention = .missingData }
    }
}

/// Matches the iOS AlertStateChip geometry, typography and attention color on artwork in either appearance.
struct LibraryArtworkChip: View {
    let state: LibraryArtworkState
    @EnvironmentObject private var loc: Localizer
    var body: some View {
        if let key = state.chipKey {
            ArtworkStatusChip(title: loc.t(key), symbol: state.symbol, color: state.color)
        }
    }
}

/// A native popover provides immediate whole-chip help and an explicit keyboard/controller activation path.
struct LibraryProfileChip: View {
    let title: String
    let explanation: String
    @Binding var showingHelp: Bool
    @State private var pinned = false

    var body: some View {
        Button { pinned.toggle(); showingHelp = pinned } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "info.circle").accessibilityHidden(true)
            }
            .font(.manrope(11, .semibold)).foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black, in: Capsule())
            .overlay(Capsule().strokeBorder(ArtworkStatusChip.neutralColor, lineWidth: ArtworkStatusChip.strokeWidth))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityHint(explanation)
        .onHover { inside in if inside { showingHelp = true } else if !pinned { showingHelp = false } }
        .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
            Text(explanation).font(.manrope(13)).padding(16).frame(width: 320, alignment: .leading)
        }
        .padTarget("hero.profile", scope: "main") { pinned = true; showingHelp = true }
    }
}
