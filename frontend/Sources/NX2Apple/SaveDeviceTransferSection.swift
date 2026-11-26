import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Shared Mac <-> iPhone/iPad save transfer controls, used by both `SavesView` and `LaunchOptionsView` (Saves tab).
struct SaveDeviceTransferSection: View {
    let game: LibraryGame?
    @ObservedObject var model: SavesModel
    @ObservedObject var saveSettings: SaveSettingsStore
    @Binding var asking: SaveTransfer.Side?
    @Binding var busy: Bool
    var support: URL? = nil
    var padScope: String = "saves"
    var showSectionHeader: Bool = false
    var showDeviceNoteInline: Bool = false
    var shortPath: (String) -> String = SaveLocationText.shown
    var running: @Sendable (String) -> Bool = { SaveTransfer.runningOnMac(titleID: $0) }
    var onMacSaveChanged: () -> Void = {}

    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @State private var result: (text: String, ok: Bool)?

    private var engine: (any SaveEngine)? { game.map { SaveEngines.forApp($0.appPath, titleID: $0.titleID) } }
    private var engineManaged: Bool { engine?.managesSavesInLauncher ?? true }
    private var isExternalMacNativeGames: Bool { engine is MacNativeGamesSaveEngine }
    private var isSharedMacNativeGames: Bool { engine is MngSharedDmSaveEngine }
    private var macSave: SaveTransfer.Contents { model.macSave }
    private var deviceSave: SaveTransfer.Contents? { model.deviceSave }
    private var deviceName: String { model.selectedDevice?.name ?? "iPhone" }
    private var transfer: SaveTransfer { model.found ?? model.template }

    private var macLocationText: String {
        switch model.macLocation {
        case .library(let url): return String(format: loc.t("saves.macLibrary"), shortPath(url.path))
        case .standard(let url): return String(format: loc.t("saves.macStandard"), shortPath(url.path))
        case .pending(let url): return String(format: loc.t("saves.macPending"), shortPath(url.path))
        }
    }

    var body: some View {
        let _ = saveSettings.revision
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if showSectionHeader {
                Text(loc.t("saves.deviceSection"))
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.textSecondary)
                    .padding(.leading, 2)
            }
            if model.showsSelector {
                HStack(spacing: DS.Space.s) {
                    Text(loc.t("saves.device")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                    LauncherDropdown(options: model.devices.map { d in
                        (value: d.id, label: d.name + (d.reachable ? "" : " (" + loc.t("dev.notConnected") + ")"))
                    }, selection: model.selected, label: loc.t("saves.device")) { model.select($0) }
                    .padTarget("saves.device", scope: padScope) {}
                }
            }
            DSSection("") {
                sideRow(.mac)
                DSRowDivider()
                sideRow(.device)
            }
            if let askingSide = asking {
                confirmation(askingSide)
            } else {
                actions
            }
            if busy {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("saves.copying")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                }
            } else if let result {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? DS.Color.statusSuccess : DS.Color.statusWarning)
                        .accessibilityHidden(true)
                    Text(result.text)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: saveSettings.revision) { _ in
            guard let game else { return }
            let resolved = resolvedMacSave(for: game)
            let updated = SaveTransfer(
                titleID: game.titleID,
                macSave: resolved.save,
                legacySave: resolved.legacy,
                device: model.template.device,
                bundle: model.template.bundle,
                devicectl: model.template.devicectl
            )
            model.updateTemplate(updated)
        }
    }

    private func resolvedMacSave(for game: LibraryGame) -> (save: URL, legacy: URL?) {
        let override = saveSettings.game(game.titleID)
        let appEngine = SaveEngines.forApp(game.appPath, titleID: game.titleID)
        if let support {
            return SaveTransfer.macSave(
                titleID: game.titleID,
                appPath: game.appPath,
                global: saveSettings.global,
                game: override,
                support: support,
                engine: appEngine
            )
        }
        return SaveTransfer.macSave(
            titleID: game.titleID,
            appPath: game.appPath,
            global: saveSettings.global,
            game: override,
            engine: appEngine
        )
    }

    private func sideRow(_ side: SaveTransfer.Side) -> some View {
        let newer = SaveTransfer.newer(mac: macSave.newest, device: deviceSave?.newest)
        let detail: String
        switch side {
        case .mac:
            detail = macSave.newest.map { String(format: loc.t("saves.saved"), dateText($0)) } ?? loc.t("saves.none")
        case .device:
            switch model.deviceState {
            case .noDevices: detail = loc.t("saves.noDevices")
            case .notConnected: detail = String(format: loc.t("saves.notConnected"), deviceName)
            case .notInstalled: detail = String(format: loc.t("saves.notInstalled"), deviceName)
            case .reading: detail = String(format: loc.t("saves.reading"), deviceName)
            case .failed(let why): detail = String(format: loc.t("saves.unreachable"), why)
            case .timedOut: detail = String(format: loc.t("saves.timeout"), deviceName)
            case .ready(let c): detail = c.newest.map { String(format: loc.t("saves.saved"), dateText($0)) } ?? loc.t("saves.none")
            }
        }
        return HStack(spacing: DS.Space.s) {
            Image(systemName: side == .mac ? "desktopcomputer" : (model.selectedDevice?.model.lowercased().contains("ipad") == true ? "ipad" : "iphone"))
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(DS.Color.symbolDefault)
                .frame(width: DS.Control.leadingSlot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(side == .mac ? loc.t("saves.mac") : deviceName)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                Text(detail)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if side == .mac {
                    Text(macLocationText)
                        .font(DS.Font.footnote)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s)
            if newer == side && (side == .mac || deviceSave != nil) {
                DSTag(loc.t("saves.newer"))
            }
        }
        .padding(.leading, DS.Space.xs)
        .padding(.trailing, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: 60)
    }

    private var actions: some View {
        let toDevice = engineManaged && !busy && deviceSave != nil && !macSave.folders.isEmpty
        let toMac = engineManaged && !busy && !(deviceSave?.folders.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSFlowRow(spacing: DS.Space.xs) {
                Button(String(format: loc.t("saves.toDevice"), deviceName)) { ask(.device) }
                    .disabled(!toDevice)
                    .padTarget("saves.toDevice", scope: padScope, enabled: toDevice) { if toDevice { ask(.device) } }
                Button(String(format: loc.t("saves.toMac"), deviceName)) { ask(.mac) }
                    .disabled(!toMac)
                    .padTarget("saves.toMac", scope: padScope, enabled: toMac) { if toMac { ask(.mac) } }
                Button(loc.t("dev.refresh")) { model.refresh() }
                    .disabled(busy || !model.canRefresh)
                    .padTarget("saves.refresh", scope: padScope, enabled: !busy && model.canRefresh) { if !busy { model.refresh() } }
                if FileManager.default.fileExists(atPath: transfer.backups.path) {
                    Button(loc.t("saves.backups")) { NSWorkspace.shared.open(transfer.backups) }
                        .padTarget("saves.backups", scope: padScope) { NSWorkspace.shared.open(transfer.backups) }
                }
            }
            .buttonStyle(DSRowButtonStyle())
            if showDeviceNoteInline {
                Text(String(format: loc.t("saves.note"), deviceName))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !engineManaged, isExternalMacNativeGames {
                Text(loc.t("mng.saves.externalNote"))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isSharedMacNativeGames && !showSectionHeader {
                Text(loc.t("mng.saves.sharedNote"))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func confirmation(_ replacing: SaveTransfer.Side) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(replacing == .device ? String(format: loc.t("saves.askToDevice"), deviceName) : String(format: loc.t("saves.askToMac"), deviceName))
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: loc.t("saves.askNote"), deviceName, shortPath(transfer.backups.path)))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DSSheetButtonRow {
                    DSSheetConfirmButtons(
                        cancelTitle: loc.t("saves.cancel"),
                        confirmTitle: loc.t("saves.replace"),
                        role: .destructive,
                        scope: padScope,
                        cancel: { asking = nil },
                        confirm: { copy(replacing) }
                    )
                }
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = loc.lang == .zh ? Locale(identifier: "zh_Hans") : (Locale.current.identifier.hasPrefix("zh") ? Locale(identifier: "en_US") : .current)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func ask(_ replacing: SaveTransfer.Side) {
        result = nil
        guard let game, !running(game.titleID) else {
            result = (String(format: loc.t("saves.running"), game?.displayName(loc.lang) ?? ""), false)
            return
        }
        asking = replacing
        focus.focused = "saves.cancel"
    }

    private func copy(_ replacing: SaveTransfer.Side) {
        asking = nil
        guard let game, let transfer = model.found else { return }
        let titleID = game.titleID
        let gameName = game.displayName(loc.lang)
        if running(titleID) {
            result = (String(format: loc.t("saves.running"), gameName), false)
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: (String, Bool)
            do {
                let backup = try replacing == .device ? transfer.macToDevice() : transfer.deviceToMac()
                if replacing == .mac {
                    CloudSaveCheck.clearBase(save: transfer.macSave)
                }
                outcome = (backup.map { String(format: loc.t("saves.copiedBackup"), shortPath($0.path)) } ?? loc.t("saves.copied"), true)
            } catch {
                outcome = (String(format: loc.t("saves.failed"), message(error)), false)
            }
            DispatchQueue.main.async {
                busy = false
                result = outcome
                if replacing == .mac && outcome.1 {
                    saveSettings.notifySaveChanged()
                    onMacSaveChanged()
                }
                model.refresh()
                focus.focused = padScope == "saves" ? "saves.done" : "opt.done"
            }
        }
    }

    private func message(_ error: Error) -> String {
        switch error as? SaveTransfer.Failure {
        case .noMacSave: return loc.t("saves.noMacSave")
        case .noDeviceSave: return String(format: loc.t("saves.noDeviceSave"), deviceName)
        case .device(let line): return line
        case .timeout: return String(format: loc.t("saves.timeout"), deviceName)
        case nil: return error.localizedDescription
        }
    }
}

/// Embedded device save transfer section inside Launch Options -> Saves, aligned with `SavesView`.
struct LaunchOptionsDeviceSavesCard: View {
    @ObservedObject var m: BuildStore
    let game: LibraryGame
    @ObservedObject var saveSettings: SaveSettingsStore
    var devicectl: DeviceControl? = nil
    var listDevices: (() -> [AppleDevice])? = nil

    @StateObject private var model: SavesModel
    @State private var asking: SaveTransfer.Side?
    @State private var busy = false

    init(
        m: BuildStore,
        game: LibraryGame,
        saveSettings: SaveSettingsStore,
        devicectl: DeviceControl? = nil,
        listDevices: (() -> [AppleDevice])? = nil,
        support: URL? = nil,
        timeout: TimeInterval = 30
    ) {
        self.m = m
        self.game = game
        self.saveSettings = saveSettings
        self.devicectl = devicectl
        self.listDevices = listDevices
        let override = saveSettings.game(game.titleID)
        let appEngine = SaveEngines.forApp(game.appPath, titleID: game.titleID)
        let mac = support.map {
            SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath, global: saveSettings.global, game: override, support: $0, engine: appEngine)
        } ?? SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath, global: saveSettings.global, game: override, engine: appEngine)
        let control = devicectl ?? .xcrun(m.devices.xcrun, runner: m.runner)
        let template = SaveTransfer(titleID: game.titleID, macSave: mac.save, legacySave: mac.legacy, device: "", bundle: "", devicectl: control)
        let known = m.devices.devices
        let xcrun = m.devices.xcrun
        let runner = m.runner
        let list: () -> [AppleDevice] = listDevices ?? (devicectl == nil ? { DeviceTools.devices(xcrun: xcrun, timeout: 10, runner: runner) } : { known })
        let key = "saveTransfer.device." + game.titleID
        _model = StateObject(wrappedValue: SavesModel(
            template: template,
            name: game.name,
            recordedBundle: NSDictionary(contentsOfFile: game.iosAppPath + "/Info.plist")?["CFBundleIdentifier"] as? String,
            recordedDevice: game.installedDevice,
            installTarget: m.devices.installDevice,
            remembered: UserDefaults.standard.string(forKey: key) ?? "",
            rememberChoice: { UserDefaults.standard.set($0, forKey: key) },
            listDevices: list,
            timeout: timeout
        ))
    }

    var body: some View {
        SaveDeviceTransferSection(
            game: game,
            model: model,
            saveSettings: saveSettings,
            asking: $asking,
            busy: $busy,
            padScope: "launch",
            showSectionHeader: true,
            showDeviceNoteInline: true,
            shortPath: m.shortPath
        )
        .onAppear { model.begin() }
        .onChange(of: game.titleID) { _ in
            asking = nil
            busy = false
        }
    }
}
