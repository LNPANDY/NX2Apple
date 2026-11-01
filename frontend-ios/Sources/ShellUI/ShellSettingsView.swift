import SwiftUI
import ShellUI
import UniformTypeIdentifiers

/// The shell-level settings: the game-data folder, the cloud-saves folder, the interface language and the default
/// performance HUD (ShellSettingsStore). A game's own settings and bookmarks win over these; these win over the
/// built-in defaults. The rows reuse the game settings' components, and the pickers use the same security-scoped
/// bookmarks as a game's own picks (BookmarkStore).
public struct ShellSettingsView: View {
    @State private var store: ShellSettingsStore
    @State private var dataNote = ""
    @State private var cloudNote = ""
    @State private var language: String
    @State private var hudOn: Bool
    private let pickFolder: (String) -> Void   // key ("data" | "cloud"), the host runs the picker

    public init(store: ShellSettingsStore = ShellSettingsStore(),
                pickFolder: @escaping (String) -> Void) {
        _store = State(initialValue: store)
        _language = State(initialValue: store.language)
        _hudOn = State(initialValue: store.performanceHUD ?? false)
        self.pickFolder = pickFolder
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(title: zh("游戏数据")) {
                    row(label: zh("统一游戏数据目录"), note: dataNote.isEmpty ? zh("新游戏优先在这里找游戏数据。每个游戏也可以单独指定。") : dataNote) {
                        Button(zh("选择文件夹…")) { pickFolder("data") }
                    }
                }
                section(title: zh("云存档")) {
                    row(label: zh("统一云存档目录"), note: cloudNote.isEmpty ? zh("选择与 Mac 相同的 iCloud Drive 文件夹，所有游戏默认共享它的存档结构。") : cloudNote) {
                        Button(zh("选择文件夹…")) { pickFolder("cloud") }
                    }
                }
                section(title: zh("界面")) {
                    row(label: zh("界面语言"), note: "") {
                        Picker("", selection: $language) {
                            Text(zh("跟随设备")).tag("")
                            Text("中文").tag("zh-Hans")
                            Text("English").tag("en")
                        }
                        .pickerStyle(.menu).onChange(of: language) { _, v in store.storeLanguage(v) }
                    }
                    row(label: zh("默认性能浮层"), note: zh("游戏未单独设置时使用。")) {
                        Toggle("", isOn: $hudOn).onChange(of: hudOn) { _, v in store.storePerformanceHUD(v) }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(zh("设置"))
    }

    @ViewBuilder private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func row<Content: View>(label: String, note: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            control()
        }
    }

    private func zh(_ s: String) -> String { s }   // the words are already the device-language pair; Localizable covers them
}
