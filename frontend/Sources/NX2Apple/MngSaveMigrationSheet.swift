import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Desktop sheet asking the player how to handle an existing legacy MNG save
/// when first enabling #2375 shared `dm` saves for a title.
struct MngSaveMigrationSheet: View {
    @ObservedObject var coordinator: MngSaveMigrationCoordinator
    @ObservedObject var saveSettings: SaveSettingsStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @State private var picked: MngSaveMigration.Choice?

    var body: some View {
        if let q = coordinator.prompt {
            content(q)
                .padScope("mngmigration", focus)
                .onChange(of: q.id) { _ in picked = nil }
        }
    }

    private func content(_ q: MngMigrationQuestion) -> some View {
        let mngDetail = detailLine(url: q.assessment.mngSource, files: mngCount(q.assessment), newest: mngDate(q.assessment))
        let nxDetail: String = {
            switch q.assessment {
            case .bothHaveSaves(_, _, let existing, _, _, let count, let newest):
                return detailLine(url: existing, files: count, newest: newest)
            case .mngOnly(_, let target, _, _):
                return (target.path as NSString).abbreviatingWithTildeInPath + " · " + loc.t("saves.none")
            case .none:
                return loc.t("saves.none")
            }
        }()
        let messageKey = q.isConflict ? "mng.migration.both.message" : "mng.migration.mngOnly.message"
        let importKey = q.isConflict ? "mng.migration.useMNG" : "mng.migration.importMNG"
        return DSSheet(
            title: loc.t("mng.migration.title"),
            message: String(format: loc.t(messageKey), q.gameName)
        ) {
            DSSection("") {
                optionRow(
                    title: loc.t(importKey),
                    detail: mngDetail,
                    symbol: "tray.and.arrow.down",
                    id: "mngmigration.import",
                    value: .importMNG,
                    disabled: q.busy
                )
                DSRowDivider()
                optionRow(
                    title: loc.t("mng.migration.keepNxnative"),
                    detail: nxDetail,
                    symbol: "desktopcomputer",
                    id: "mngmigration.keep",
                    value: .keepNxnative,
                    disabled: q.busy
                )
            }
            Text(loc.t("mng.migration.backupKeptNote"))
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = q.error {
                DSInlineWarning(error)
            }
        } buttons: {
            Button(loc.t("mng.migration.cancel")) {
                coordinator.cancel()
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            .disabled(q.busy)
            .padTarget("mngmigration.cancel", scope: "mngmigration", enabled: !q.busy) {
                if !q.busy { coordinator.cancel() }
            }

            DSSheetPrimaryButton(loc.t("cloudCheck.useSelected"), takesReturn: false) {
                if let picked {
                    coordinator.choose(picked, saveSettings: saveSettings)
                }
            }
            .disabled(picked == nil || q.busy)
            .padTarget(
                "mngmigration.confirm",
                scope: "mngmigration",
                focusColor: DS.Color.accentOn,
                enabled: picked != nil && !q.busy
            ) {
                if let picked, !q.busy {
                    coordinator.choose(picked, saveSettings: saveSettings)
                }
            }
        }
    }

    private func optionRow(
        title: String,
        detail: String,
        symbol: String,
        id: String,
        value: MngSaveMigration.Choice,
        disabled: Bool
    ) -> some View {
        let selected = picked == value
        let action = { if !disabled { picked = value } }
        return Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Color.symbolDefault)
                    .frame(width: DS.Control.leadingSlot)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                    Text(detail)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.xs)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? DS.Color.symbolAccent : DS.Color.symbolDefault)
            }
            .padding(.leading, DS.Space.xs)
            .padding(.trailing, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padTarget(id, scope: "mngmigration", radius: DS.Radius.card, enabled: !disabled, activate: action)
    }

    private func mngCount(_ a: MngSaveMigration.Assessment) -> Int {
        switch a {
        case .none: return 0
        case .mngOnly(_, _, let c, _): return c
        case .bothHaveSaves(_, _, _, let c, _, _, _): return c
        }
    }

    private func mngDate(_ a: MngSaveMigration.Assessment) -> Date? {
        switch a {
        case .none: return nil
        case .mngOnly(_, _, _, let d): return d
        case .bothHaveSaves(_, _, _, _, let d, _, _): return d
        }
    }

    private func detailLine(url: URL?, files: Int, newest: Date?) -> String {
        let short = url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        let countText = String(format: loc.t("mng.migration.fileCount"), files)
        let timeText = newest.map { CloudSaveText.time($0, lang: loc.lang.code, unknown: loc.t("cloudCheck.unknownTime")) }
        return [short, countText, timeText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Console-mode full-screen migration selector when launching a #2375 MNG game with a controller.
struct ConsoleMngMigrationView: View {
    let question: MngMigrationQuestion
    let lang: Lang
    let compact: Bool
    let choose: (MngSaveMigration.Choice) -> Void
    let cancel: () -> Void

    static let scope = "console.mngMigration"
    static let firstFocus = "console.mngMigration.import"

    private func t(_ key: String) -> String { L10n.string(key, lang) }

    var body: some View {
        let importTitle = t(question.isConflict ? "mng.migration.useMNG" : "mng.migration.importMNG")
        let mngDetail = question.assessment.mngSource.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        let nxDetail: String = {
            switch question.assessment {
            case .bothHaveSaves(_, _, let existing, _, _, let files, _):
                return (existing.path as NSString).abbreviatingWithTildeInPath + " · " + String(format: t("mng.migration.fileCount"), files)
            case .mngOnly(_, let target, _, _):
                return (target.path as NSString).abbreviatingWithTildeInPath + " · " + t("saves.none")
            case .none:
                return t("saves.none")
            }
        }()
        return VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            Text(question.gameName)
                .font(compact ? DS.Font.headline : DS.Font.title)
                .foregroundStyle(DS.Color.textPrimary)
            Text(String(format: t(question.isConflict ? "mng.migration.both.message" : "mng.migration.mngOnly.message"), question.gameName))
                .font(compact ? DS.Font.body : DS.Font.headline)
                .foregroundStyle(DS.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            optionButton("tray.and.arrow.down", importTitle, mngDetail, id: "console.mngMigration.import", primary: true) {
                choose(.importMNG)
            }
            optionButton("desktopcomputer", t("mng.migration.keepNxnative"), nxDetail, id: "console.mngMigration.keep") {
                choose(.keepNxnative)
            }
            Text(t("mng.migration.backupKeptNote"))
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(action: cancel) {
                Text(t("mng.migration.cancel"))
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(DS.Color.surfaceRaised, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padTarget("console.mngMigration.cancel", scope: Self.scope, activate: cancel)
        }
        .padding(.horizontal, compact ? 24 : 40)
        .padding(.bottom, compact ? 24 : 40)
    }

    private func optionButton(
        _ symbol: String,
        _ title: String,
        _ detail: String,
        id: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 22 : 26, weight: .medium))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(compact ? DS.Font.bodyStrong : DS.Font.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(DS.Font.callout)
                        .opacity(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(primary ? DS.Color.accentOn : DS.Color.textPrimary)
            .padding(.horizontal, 22)
            .padding(.vertical, compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary ? DS.Color.accent : DS.Color.surface, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padTarget(id, scope: Self.scope, radius: 16, activate: action)
    }
}

extension View {
    /// Presents the desktop MNG first-time shared-save migration sheet when `coordinator.isActive`.
    func mngSaveMigrationSheet(
        _ coordinator: MngSaveMigrationCoordinator,
        saveSettings: SaveSettingsStore,
        pad: PadFocus,
        scope: @escaping () -> String
    ) -> some View {
        sheet(isPresented: Binding(get: { coordinator.isActive }, set: { if !$0 { coordinator.cancel() } })) {
            MngSaveMigrationSheet(coordinator: coordinator, saveSettings: saveSettings)
                .environmentObject(pad)
        }
        .onChange(of: coordinator.isActive) { active in
            pad.scope = active ? "mngmigration" : scope()
        }
    }
}
