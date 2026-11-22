import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Conflict resolution sheet presented by `CloudSavesCard` when both the local save and `save.dmsync`
/// changed since the last sync, letting the player pick which side to keep while backing up the other.
struct CloudSyncConflictSheet: View {
    let prompt: CloudSaveSyncStore.ConflictPrompt
    let cancel: () -> Void
    let choose: (CloudSaveCheck.Choice) -> Void

    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @State private var picked: CloudSaveCheck.Choice?

    init(
        prompt: CloudSaveSyncStore.ConflictPrompt,
        picked: CloudSaveCheck.Choice? = nil,
        cancel: @escaping () -> Void,
        choose: @escaping (CloudSaveCheck.Choice) -> Void
    ) {
        self.prompt = prompt
        self.cancel = cancel
        self.choose = choose
        _picked = State(initialValue: picked)
    }

    var body: some View {
        let cloudDetail = String(
            format: loc.t("cloudCheck.useCloud.detail"),
            CloudSaveText.device(prompt.cloud.device),
            CloudSaveText.time(prompt.cloud.saved, lang: loc.lang.code, unknown: loc.t("cloudCheck.unknownTime"))
        )
        let localDetail = String(
            format: loc.t("cloudCheck.useLocal.detail"),
            CloudSaveText.time(prompt.local.saved, lang: loc.lang.code, unknown: loc.t("cloudCheck.unknownTime"))
        )

        DSSheet(title: loc.t("cloudCheck.choose.title"), message: prompt.plan.gameName) {
            DSSection("") {
                optionRow(
                    titleKey: "cloudCheck.row.cloud",
                    detail: cloudDetail,
                    symbol: "icloud",
                    id: "cloudsync.cloud",
                    value: .cloud
                )
                DSRowDivider()
                optionRow(
                    titleKey: "cloudCheck.row.local",
                    detail: localDetail,
                    symbol: "desktopcomputer",
                    id: "cloudsync.local",
                    value: .local
                )
            }
            Text(loc.t("cloudCheck.kept"))
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Button(loc.t("cloudCheck.cancel"), action: cancel)
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("cloudsync.cancel", scope: "cloudsync", activate: cancel)
            DSSheetPrimaryButton(loc.t("cloudCheck.useSelected"), takesReturn: false) {
                if let picked { choose(picked) }
            }
            .disabled(picked == nil)
            .padTarget("cloudsync.use", scope: "cloudsync", focusColor: DS.Color.accentOn, enabled: picked != nil) {
                if let picked { choose(picked) }
            }
        }
        .padScope("cloudsync", focus)
    }

    private func optionRow(
        titleKey: String,
        detail: String,
        symbol: String,
        id: String,
        value: CloudSaveCheck.Choice
    ) -> some View {
        let selected = picked == value
        let action = { picked = value }
        return Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Color.symbolDefault)
                    .frame(width: DS.Control.leadingSlot)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(loc.t(titleKey))
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
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padTarget(id, scope: "cloudsync", radius: DS.Radius.card, activate: action)
    }
}
