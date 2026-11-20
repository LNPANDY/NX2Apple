import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The words of the check before a start (#957), shared by the desktop sheet and the console mode.
enum CloudSaveText {
    /// The device a save came from, by the model the engine wrote (`hw.model`, `hw.machine`): "iPhone17,1" is an iPhone.
    static func device(_ model: String?) -> String {
        let m = model ?? ""
        if m.hasPrefix("iPhone") { return "iPhone" }
        if m.hasPrefix("iPad") { return "iPad" }
        if m.contains("Mac") { return "Mac" }
        return m.isEmpty || m == "unknown" ? "?" : m
    }

    /// A save's time in the launcher's language.
    static func time(_ date: Date?, lang: String, unknown: String) -> String {
        guard let date else { return unknown }
        let f = DateFormatter()
        f.locale = Locale(identifier: lang)
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    static func cloudDetail(_ q: CloudSaveQuestion, _ t: (String) -> String, lang: String) -> String {
        String(format: t("cloudCheck.useCloud.detail"), device(q.cloud?.device), time(q.cloud?.saved, lang: lang, unknown: t("cloudCheck.unknownTime")))
    }

    static func localDetail(_ q: CloudSaveQuestion, _ t: (String) -> String, lang: String) -> String {
        String(format: t("cloudCheck.useLocal.detail"), time(q.local.saved, lang: lang, unknown: t("cloudCheck.unknownTime")))
    }
}

/// The desktop's check before a start: the wait for the cloud's save with Cancel, and the question when the two saves differ or
/// the cloud's cannot be read, on the sheet layout. Each answer is a button the keyboard and a
/// controller reach (scope `cloudsave`). Choosing a save is never the Return key's: the other save is only a backup then.
struct CloudSaveSheet: View {
    @ObservedObject var gate: CloudSaveGate
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @State private var picked: CloudSaveCheck.Choice?   // no row is preselected: the other save is backed up, so the player has to say which one

    init(gate: CloudSaveGate, picked: CloudSaveCheck.Choice? = nil) {
        self.gate = gate
        _picked = State(initialValue: picked)   // visual QA: a row already chosen
    }

    var body: some View {
        Group {
            switch gate.step {
            case let .fetching(name, long): fetching(name, long: long)
            case let .asking(q): asking(q)
            case nil: EmptyView()
            }
        }
        .padScope("cloudsave", focus)
    }

    private func fetching(_ name: String, long: Bool) -> some View {
        DSSheet(title: loc.t("cloudCheck.fetching.title"), message: String(format: loc.t("cloudCheck.fetching.note"), name)) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text(long ? loc.t("cloudCheck.fetching.long") : loc.t("cloudCheck.fetching.wait")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            cancel
            if long {
                DSSheetPrimaryButton(loc.t("cloudCheck.playLocal"), takesReturn: false) { gate.choose(.offline) }
                    .padTarget("cloudsave.offline", scope: "cloudsave", focusColor: DS.Color.accentOn) { gate.choose(.offline) }
            }
        }
    }

    @ViewBuilder private func asking(_ q: CloudSaveQuestion) -> some View {
        if q.outcome == .unreadable {
            DSSheet(title: loc.t("cloudCheck.unreadable.title"), message: String(format: loc.t("cloudCheck.unreadable.note"), q.gameName)) {
                if let reason = q.reason { DSInlineWarning(reason) }
                Text(loc.t("cloudCheck.playLocal.detail")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            } buttons: {
                cancel
                Button(loc.t("cloudCheck.playLocal")) { gate.choose(.offline) }.buttonStyle(DSSecondaryButtonStyle())
                    .padTarget("cloudsave.local", scope: "cloudsave") { gate.choose(.offline) }
                DSSheetPrimaryButton(loc.t("cloudCheck.retry")) { gate.retry() }
                    .help(loc.t("cloudCheck.retry.detail"))
                    .padTarget("cloudsave.retry", scope: "cloudsave", focusColor: DS.Color.accentOn) { gate.retry() }
            }
        } else {
            DSSheet(title: loc.t("cloudCheck.choose.title"), message: q.gameName) {
                DSSection("") {
                    option("cloudCheck.row.cloud", detail: CloudSaveText.cloudDetail(q, loc.t, lang: loc.lang.code), symbol: "icloud", id: "cloudsave.cloud", value: .cloud)
                    DSRowDivider()
                    option("cloudCheck.row.local", detail: CloudSaveText.localDetail(q, loc.t, lang: loc.lang.code), symbol: "desktopcomputer", id: "cloudsave.local", value: .local)
                }
                Text(loc.t("cloudCheck.kept")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            } buttons: {
                cancel
                DSSheetPrimaryButton(loc.t("cloudCheck.useSelected"), takesReturn: false) { if let picked { gate.choose(picked) } }   // never the default: a save becomes a backup
                    .disabled(picked == nil)
                    .padTarget("cloudsave.use", scope: "cloudsave", focusColor: DS.Color.accentOn, enabled: picked != nil) { if let picked { gate.choose(picked) } }
            }
        }
    }

    private var cancel: some View {
        Button(loc.t("cloudCheck.cancel")) { gate.cancel() }.buttonStyle(DSSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            .padTarget("cloudsave.cancel", scope: "cloudsave") { gate.cancel() }
    }

    /// A selectable row of the list: the whole row is the target, the chosen one gets the accent check (selection).
    private func option(_ key: String, detail: String, symbol: String, id: String, value: CloudSaveCheck.Choice) -> some View {
        let selected = picked == value
        let action = { picked = value }
        return Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.Color.symbolDefault).frame(width: DS.Control.leadingSlot)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(loc.t(key)).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                    Text(detail).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.xs)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 16))
                    .foregroundStyle(selected ? DS.Color.symbolAccent : DS.Color.symbolDefault)
            }
            .padding(.leading, DS.Space.xs).padding(.trailing, DS.Space.m).padding(.vertical, DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padTarget(id, scope: "cloudsave", radius: DS.Radius.card, activate: action)
    }
}

extension View {
    /// The check before a start, over the launcher while the gate has a step.
    func cloudSaveSheet(_ gate: CloudSaveGate, pad: PadFocus, scope: @escaping () -> String) -> some View {
        sheet(isPresented: Binding(get: { gate.isActive }, set: { if !$0 { gate.cancel() } })) {
            CloudSaveSheet(gate: gate).environmentObject(pad)
        }
        .onChange(of: gate.isActive) { active in pad.scope = active ? "cloudsave" : scope() }
    }
}
