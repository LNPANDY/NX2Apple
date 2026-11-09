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
/// the cloud's cannot be read. Each answer is a button the keyboard and a controller reach (scope `cloudsave`).
struct CloudSaveSheet: View {
    @ObservedObject var gate: CloudSaveGate
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @State private var picked: CloudSaveCheck.Choice?   // no row is preselected: the other save is backed up, so the player has to say which one

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch gate.step {
            case let .fetching(name, long): fetching(name, long: long)
            case let .asking(q): asking(q)
            case nil: EmptyView()
            }
        }
        .padScope("cloudsave", focus)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .launcherAppearance()
        .tint(LauncherPalette.cream)
    }

    private func heading(_ symbol: String, _ title: String, _ note: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(LauncherPalette.cream)
                .frame(width: 40, height: 40).background(LauncherPalette.cream.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.manrope(22, .heavy)).tracking(-0.4).fixedSize(horizontal: false, vertical: true)
                Text(note).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
    }

    private func fetching(_ name: String, long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("icloud.and.arrow.down", loc.t("cloudCheck.fetching.title"), String(format: loc.t("cloudCheck.fetching.note"), name))
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(long ? loc.t("cloudCheck.fetching.long") : loc.t("cloudCheck.fetching.wait")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
            footer {
                if long { secondary("cloudCheck.playLocal", id: "cloudsave.offline") { gate.choose(.offline) } }
                secondary("cloudCheck.cancel", id: "cloudsave.cancel") { gate.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder private func asking(_ q: CloudSaveQuestion) -> some View {
        if q.outcome == .unreadable {
            heading("icloud.slash", loc.t("cloudCheck.unreadable.title"), String(format: loc.t("cloudCheck.unreadable.note"), q.gameName))
            VStack(alignment: .leading, spacing: 10) {
                if let reason = q.reason { Text(reason).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                choice("cloudCheck.retry", detail: loc.t("cloudCheck.retry.detail"), symbol: "arrow.clockwise", id: "cloudsave.retry", primary: true) { gate.retry() }
                choice("cloudCheck.playLocal", detail: loc.t("cloudCheck.playLocal.detail"), symbol: "desktopcomputer", id: "cloudsave.local") { gate.choose(.offline) }
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
            footer { secondary("cloudCheck.cancel", id: "cloudsave.cancel") { gate.cancel() }.keyboardShortcut(.cancelAction) }
        } else {
            heading("arrow.triangle.2.circlepath.icloud", loc.t("cloudCheck.choose.title"), q.gameName)
            VStack(alignment: .leading, spacing: 10) {
                option("cloudCheck.row.cloud", detail: CloudSaveText.cloudDetail(q, loc.t, lang: loc.lang.code), symbol: "icloud", id: "cloudsave.cloud", value: .cloud)
                option("cloudCheck.row.local", detail: CloudSaveText.localDetail(q, loc.t, lang: loc.lang.code), symbol: "desktopcomputer", id: "cloudsave.local", value: .local)
                Text(loc.t("cloudCheck.kept")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
            footer {
                secondary("cloudCheck.cancel", id: "cloudsave.cancel") { gate.cancel() }.keyboardShortcut(.cancelAction)
                Button(loc.t("cloudCheck.useSelected")) { if let picked { gate.choose(picked) } }
                    .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.cream)).disabled(picked == nil)   // no Return shortcut: a destructive choice is never the default
                    .padTarget("cloudsave.use", scope: "cloudsave") { if let picked { gate.choose(picked) } }
            }
        }
    }

    /// A selectable row: the whole row is the target, the chosen one gets the cream outline and a check.
    private func option(_ key: String, detail: String, symbol: String, id: String, value: CloudSaveCheck.Choice) -> some View {
        let selected = picked == value
        let action = { picked = value }
        return Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t(key)).font(.manrope(14.5, .bold))
                    Text(detail).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 16)).foregroundStyle(selected ? LauncherPalette.cream : .secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? LauncherPalette.cream : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padTarget(id, scope: "cloudsave", radius: 12, activate: action)
    }

    private func choice(_ key: String, detail: String, symbol: String, id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t(key)).font(.manrope(14.5, .bold))
                    Text(detail).font(.manrope(12)).opacity(0.75).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(primary ? LauncherPalette.background : LauncherPalette.textStrong)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary ? LauncherPalette.cream : LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padTarget(id, scope: "cloudsave", radius: 12, activate: action)
    }

    private func footer(@ViewBuilder _ buttons: () -> some View) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            HStack(spacing: 12) { Spacer(minLength: 8); buttons() }.padding(.horizontal, 28).padding(.vertical, 16)
        }
    }

    private func secondary(_ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(loc.t(key), action: action).buttonStyle(LauncherSecondaryButtonStyle()).padTarget(id, scope: "cloudsave", activate: action)
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
