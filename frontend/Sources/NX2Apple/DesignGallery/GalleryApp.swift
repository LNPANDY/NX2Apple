import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NXCore
import NXLauncher

/// The state gallery (LNPANDY/NX2Apple#1459): `NX2Apple --gallery` or `NX_GALLERY=1` opens a developer window with every view and
/// state of the launcher (GalleryScene) instead of the launcher. It is a separate app: the launcher's window, its session and stores,
/// the onboarding, the engine sync, the update check and the console coordinator are never made. Each scene runs on fixture stores
/// (GalleryFixtures). The window's own texts are English only: it is not shown to players.
enum GalleryMode {
    static var requested: Bool {
        CommandLine.arguments.contains("--gallery") || ProcessInfo.processInfo.environment["NX_GALLERY"] == "1"
    }
}

struct GalleryApp: App {
    @NSApplicationDelegateAdaptor private var delegate: GalleryAppDelegate

    var body: some Scene {
        WindowGroup("NX2Apple State Gallery") {
            GalleryWindow().launcherAppearance()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1560, height: 960)
    }
}

/// Keeps the app's own defaults as they were: a view in a scene that saves straight to `UserDefaults.standard` (a library sort, a
/// filter) is undone when the gallery quits, so the launcher starts next time with the player's settings untouched.
final class GalleryAppDelegate: NSObject, NSApplicationDelegate {
    private var snapshot: [String: Any]?
    private var domain: String? { Bundle.main.bundleIdentifier }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let domain { snapshot = UserDefaults.standard.persistentDomain(forName: domain) ?? [:] }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let domain, let snapshot else { return }
        UserDefaults.standard.setPersistentDomain(snapshot, forName: domain)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The gallery's window: the scenes by group on the left with a search, the chosen one live on the right (real views, interactive,
/// controller focus included), a language, a window size and the PNG export in the toolbar.
struct GalleryWindow: View {
    enum SizePreset: String, CaseIterable, Identifiable {
        case standard = "1280 x 800", narrow = "900 x 680", large = "1600 x 1000"
        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .standard: return CGSize(width: 1280, height: 800)
            case .narrow: return CGSize(width: 900, height: 680)
            case .large: return CGSize(width: 1600, height: 1000)
            }
        }
    }

    @State private var selection: GalleryScene? = .libraryGames
    @State private var query = ""
    @State private var langCode = Lang.en.code
    @State private var preset: SizePreset = .standard
    @State private var fixtures = GalleryFixtures(lang: .en)
    @State private var status = ""

    private var lang: Lang { Lang.find(langCode) ?? .en }

    private func size(of scene: GalleryScene) -> CGSize { scene.resizable ? preset.size : scene.size }

    private var filtered: [GalleryScene] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return GalleryScene.allCases }
        return GalleryScene.allCases.filter {
            $0.title.lowercased().contains(needle) || $0.group.rawValue.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(GalleryScene.Group.allCases) { group in
                    let scenes = filtered.filter { $0.group == group }
                    if !scenes.isEmpty {
                        Section(group.rawValue) {
                            ForEach(scenes) { scene in Text(scene.title).tag(scene) }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Find a view or state")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let scene = selection {
                let frame = size(of: scene)
                ScrollView([.horizontal, .vertical]) {
                    fixtures.liveView(scene, size: frame)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                        .padding(DS.Space.l)
                        .id(scene.id + lang.code + preset.rawValue)
                }
                .background(DS.Color.surface)
                .navigationTitle(scene.group.rawValue + ": " + scene.title)
            } else {
                Text("Choose a view").foregroundStyle(DS.Color.textSecondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Language", selection: $langCode) {
                    ForEach(Lang.all, id: \.code) { Text($0.code).tag($0.code) }
                }
                .help("The language of the scene")
                Picker("Window size", selection: $preset) {
                    ForEach(SizePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("The window size of the scene. A sheet keeps its own size.")
                Button("Export PNG", action: exportCurrent).disabled(selection == nil)
                Button("Export all…", action: exportAll)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !status.isEmpty {
                Text(status).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .padding(DS.Space.xs).frame(maxWidth: .infinity, alignment: .leading).background(DS.Color.background)
            }
        }
        .onChange(of: langCode) { _ in fixtures = GalleryFixtures(lang: lang) }
    }

    private func exportCurrent() {
        guard let scene = selection else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(scene.id)-\(lang.code).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = GalleryRenderer.png(scene, fixtures: fixtures, size: size(of: scene)) {
            status = (try? data.write(to: url)) != nil ? "Saved \(url.path)" : "Could not save \(url.path)"
        }
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var written = 0
        for scene in GalleryScene.allCases {
            guard let data = GalleryRenderer.png(scene, fixtures: fixtures, size: size(of: scene)) else { continue }
            if (try? data.write(to: folder.appendingPathComponent("\(scene.id)-\(lang.code).png"))) != nil { written += 1 }
        }
        status = "Exported \(written) of \(GalleryScene.allCases.count) scenes to \(folder.path)"
    }
}
