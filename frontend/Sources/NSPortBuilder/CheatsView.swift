import AppKit
import SwiftUI

/// The Cheats sheet (#97): a game's cheat files, an on / off switch per cheat, an import by drop or pick, and a copy to the
/// iPhone or iPad the game was installed on. The files and what the switches write are CheatFiles.swift (the contract of
/// docs/frontends.md "Cheats"), so this is only the view. It never touches a running game: the host reads the files when it
/// starts (or on its own Reload cheats).
struct CheatsView: View {
    @ObservedObject var m: BuildModel
    @ObservedObject var library: GameLibrary
    let gameID: UUID
    var devicectl: DeviceControl? = nil   // tests and the visual QA hand in a stand-in
    var support: URL? = nil               // the Application Support folder; tests use a temporary one
    var dropped = false                   // the drop highlight drawn from the start (visual QA)
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var focus: PadFocus

    @State private var files: [CheatFiles.Found] = []
    @State private var cheats: [CheatFiles.Cheat] = []
    @State private var on: Set<String> = []
    @State private var master = true
    @State private var safeMode = false
    @State private var busy = false
    @State private var result: (text: String, ok: Bool)?

    private var game: LibraryGame? { library.games.first { $0.id == gameID } }
    private var deviceName: String { game.map { m.deviceName($0.installedDevice) } ?? "iPhone" }

    private var cheatFiles: CheatFiles? {
        guard let game else { return nil }
        return support.map { CheatFiles(titleID: game.titleID, support: $0) } ?? CheatFiles(titleID: game.titleID)
    }

    private var buildID: String? { game.flatMap { CheatFiles.buildID(appPath: $0.appPath, iosAppPath: $0.iosAppPath) } }
    private var current: CheatFiles.Found? { buildID.flatMap { id in files.first { $0.buildID == id } } }
    private var bundle: String { game.flatMap { NSDictionary(contentsOfFile: $0.iosAppPath + "/Info.plist")?["CFBundleIdentifier"] as? String } ?? "" }
    private var canCopy: Bool { !busy && (game?.onDevice ?? false) && !bundle.isEmpty && !files.isEmpty }
    private var shown: [CheatFiles.Cheat] { cheats.filter { !$0.pairOff && !($0.kind == .label && $0.name.isEmpty) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.t("cheats.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                if let game { Text(game.name).font(.manrope(14)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 14) {
                buildCard
                if game?.cheatsNeedIOSNote ?? false { iosNoteCard }
                if files.isEmpty { emptyCard } else { listCard }
                actions
                if busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(m.t("cheats.copying")).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                } else if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.manrope(13)).foregroundStyle(result.ok ? LauncherPalette.ready : LauncherPalette.building)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 30)
            Spacer(minLength: 0)
            Divider().opacity(0.3)
            HStack(spacing: 14) {
                Text(m.t("cheats.note") + ((game?.onDevice ?? false) ? " " + String(format: m.t("cheats.noteDevice"), deviceName) : "")).font(.manrope(12)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Text(m.t("launch.done")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(busy)
                .padTarget("cheats.done", scope: "cheats", radius: 20) { if !busy { dismiss() } }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .padScope("cheats", focus)
        .frame(width: 600, height: 700)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .modifier(GameFilesDrop(enabled: !busy, label: m.t("cheats.dropHint"), targeted: dropped) { importPaths($0) })
        .onAppear(perform: refresh)
    }

    // ---- the cards ----

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }

    /// The build the game is, and the master switch.
    private var buildCard: some View {
        card {
            HStack(spacing: 14) {
                Image(systemName: "number").font(.system(size: 16, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.t("cheats.buildLabel")).font(.manrope(14, .medium))
                    Text(buildID ?? m.t("cheats.buildUnknown")).font(buildID == nil ? .manrope(12) : .system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            Divider().opacity(0.25).padding(.leading, 18)
            HStack(spacing: 14) {
                Image(systemName: "power").font(.system(size: 16, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.t("cheats.master")).font(.manrope(14, .medium))
                    if safeMode {
                        Text(m.t("cheats.safeMode")).font(.manrope(12)).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { master }, set: { setMaster($0) })).toggleStyle(CheatSwitchStyle()).labelsHidden()
                    .accessibilityLabel(m.t("cheats.master"))
                    .padTarget("cheats.master", scope: "cheats") { setMaster(!master) }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
        }
    }

    /// Cheats do not run on iPhone or iPad yet: said once, calmly, with the switches left usable for a Mac build.
    private var iosNoteCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "info.circle").font(.system(size: 16, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
            Text(m.t("cheats.iosNote")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var emptyCard: some View {
        card {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                Text(m.t("cheats.empty")).font(.manrope(13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 150).padding(18)
        }
    }

    /// The files by build, the ones for another build marked, and the cheats of the build the game is.
    private var listCard: some View {
        card {
            ForEach(files) { file in
                fileRow(file)
                Divider().opacity(0.25).padding(.leading, 18)
            }
            if current == nil {
                Text(buildID == nil ? m.t("cheats.noBuildFile") : String(format: m.t("cheats.noFileForBuild"), buildID ?? ""))
                    .font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) { ForEach(Array(shown.enumerated()), id: \.element.id) { cheatRow($0.element, index: $0.offset) } }
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func fileRow(_ file: CheatFiles.Found) -> some View {
        let isCurrent = file.buildID == buildID
        return HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 15, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
            Text(file.buildID + ".txt").font(.system(size: 12.5, design: .monospaced))
            Spacer(minLength: 8)
            Text((isCurrent ? m.t("cheats.thisBuild") : m.t("cheats.otherBuild")).uppercased()).font(.manrope(10.5, .bold)).tracking(1.1)
                .foregroundStyle(isCurrent ? .black : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isCurrent ? AnyShapeStyle(LauncherPalette.cream) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .opacity(isCurrent ? 1 : 0.6)
        .help(isCurrent ? "" : m.t("cheats.otherHint"))
    }

    @ViewBuilder private func cheatRow(_ cheat: CheatFiles.Cheat, index: Int) -> some View {
        let first = index == 0 || shown[index - 1].section != cheat.section
        if first && !cheat.section.isEmpty {
            Text(cheat.section.uppercased()).font(.manrope(10.5, .bold)).tracking(1.1).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
        }
        switch cheat.kind {
        case .label where cheat.name.hasPrefix("--Section"):
            EmptyView()
        case .label:
            Text(cheat.name).font(.manrope(12)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 5)
        case .master:
            HStack(spacing: 10) {
                Text(cheat.name).font(.manrope(13))
                Spacer(minLength: 8)
                Text(m.t("cheats.alwaysOn")).font(.manrope(11.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
        case .cheat:
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(cheat.name).font(.manrope(13)).lineLimit(2)
                    if cheat.broken { Text(m.t("cheats.broken")).font(.manrope(11.5)).foregroundStyle(LauncherPalette.building) }
                    else if cheat.once { Text(m.t("cheats.once")).font(.manrope(11.5)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if cheat.switchable {
                    Toggle("", isOn: Binding(get: { on.contains(cheat.key) }, set: { set(cheat, $0) })).toggleStyle(CheatSwitchStyle()).labelsHidden()
                        .accessibilityLabel(cheat.name)
                        .padTarget("cheats.row.\(cheat.key)", scope: "cheats") { set(cheat, !on.contains(cheat.key)) }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 5)
        }
    }

    /// Import, the folder, and the copy to the device.
    private var actions: some View {
        HStack(spacing: 10) {
            Button(m.t("cheats.import")) { pick() }.disabled(busy)
                .padTarget("cheats.import", scope: "cheats") { if !busy { pick() } }
            Button(m.t("cheats.showFolder")) { showFolder() }
                .padTarget("cheats.folder", scope: "cheats") { showFolder() }
            Spacer(minLength: 8)
            if game?.onDevice ?? false {
                Button(String(format: m.t("cheats.toDevice"), deviceName)) { copyToDevice() }.disabled(!canCopy)
                    .padTarget("cheats.toDevice", scope: "cheats") { if canCopy { copyToDevice() } }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    // ---- what the controls do ----

    private func refresh() {
        guard let cheatFiles else { return }
        files = cheatFiles.found()
        master = cheatFiles.masterOn
        safeMode = cheatFiles.safeMode
        if let file = current { cheats = cheatFiles.cheats(of: file) ?? []; on = cheatFiles.enabled(file.buildID) } else { cheats = []; on = [] }
    }

    private func set(_ cheat: CheatFiles.Cheat, _ value: Bool) {
        guard let cheatFiles, let file = current else { return }
        var next = on
        if value { next.insert(cheat.key) } else { next.remove(cheat.key) }
        do {
            try cheatFiles.writeEnabled(file.buildID, cheats: cheats, on: next)
            on = next
            result = game.flatMap { CheatsView.running(game: $0) ? (String(format: m.t("cheats.running"), $0.name), false) : nil }
        } catch { result = (String(format: m.t("cheats.writeFailed"), error.localizedDescription), false) }
    }

    private func setMaster(_ value: Bool) {
        guard let cheatFiles else { return }
        do { try cheatFiles.setMaster(value); master = value } catch { result = (String(format: m.t("cheats.writeFailed"), error.localizedDescription), false) }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = m.t("cheats.pickMessage")
        if panel.runModal() == .OK { importPaths(panel.urls.map(\.path)) }
    }

    private func importPaths(_ paths: [String]) {
        guard let cheatFiles else { return }
        do {
            let outcome = try cheatFiles.importFiles(from: paths.map { URL(fileURLWithPath: $0) })
            refresh()
            result = Self.importMessage(outcome, m: m)
        } catch { result = (String(format: m.t("cheats.writeFailed"), error.localizedDescription), false) }
    }

    /// What an import says: how many files came in, and the ones without a build ID in their name.
    static func importMessage(_ r: CheatFiles.ImportResult, m: BuildModel) -> (String, Bool) {
        var parts: [String] = []
        if !r.imported.isEmpty { parts.append(String(format: m.t("cheats.imported"), r.imported.count)) }
        if !r.skipped.isEmpty { parts.append(String(format: m.t("cheats.notNamed"), r.skipped.prefix(3).joined(separator: ", "))) }
        if parts.isEmpty { return (m.t("cheats.nothingFound"), false) }
        return (parts.joined(separator: " "), !r.imported.isEmpty)
    }

    private func showFolder() {
        guard let cheatFiles else { return }
        try? FileManager.default.createDirectory(at: cheatFiles.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(cheatFiles.folder)
    }

    private func copyToDevice() {
        guard let cheatFiles, let game else { return }
        let transfer = CheatTransfer(files: cheatFiles, device: game.installedDevice, bundle: bundle, devicectl: devicectl ?? .xcrun(m.xcrunPath))
        busy = true; result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: (String, Bool)
            do { try transfer.toDevice(); outcome = (String(format: m.t("cheats.copied"), deviceName), true) }
            catch CheatTransfer.Failure.noFiles { outcome = (m.t("cheats.empty"), false) }
            catch CheatTransfer.Failure.device(let line) { outcome = (String(format: m.t("cheats.copyFailed"), line), false) }
            catch { outcome = (String(format: m.t("cheats.copyFailed"), error.localizedDescription), false) }
            DispatchQueue.main.async { busy = false; result = outcome; focus.focused = "cheats.done" }
        }
    }

    static func running(game: LibraryGame) -> Bool { SaveTransfer.runningOnMac(titleID: game.titleID) }
}

extension View {
    /// The Cheats sheet of the game `id` names, with the controller's scope following it (the launcher's other sheets do the same inline).
    func cheatsSheet(for id: Binding<UUID?>, m: BuildModel, library: GameLibrary, pad: PadFocus, restoreScope: @escaping () -> String) -> some View {
        sheet(isPresented: Binding(get: { id.wrappedValue != nil }, set: { if !$0 { id.wrappedValue = nil } })) {
            if let game = id.wrappedValue { CheatsView(m: m, library: library, gameID: game).environmentObject(pad) }
        }
        .onChange(of: id.wrappedValue) { open in pad.scope = open != nil ? "cheats" : restoreScope() }
    }
}

/// An on / off switch that reads the same in a window that is not key (the system's drops its colour there): cream when on, a dim track when off.
struct CheatSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? LauncherPalette.cream : Color.white.opacity(0.16))
                .frame(width: 40, height: 23)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? Color.black.opacity(0.85) : Color.white.opacity(0.85)).frame(width: 17, height: 17).padding(3)
                }
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "1" : "0")
    }
}
