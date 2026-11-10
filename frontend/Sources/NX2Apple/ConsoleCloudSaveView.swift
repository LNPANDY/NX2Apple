import SwiftUI
import NXCore
import NXLauncher

/// The console mode's question before a start (#957), in the sheet: the two saves with where and when each was made, or, when
/// the cloud's could not be read, Try again and Play with this Mac's save. Every answer is a large button a controller reaches
/// (scope `console.cloudSave`); B, the close button and Cancel leave the game unstarted.
struct ConsoleCloudSaveView: View {
    let question: CloudSaveQuestion
    let lang: Lang
    let compact: Bool
    let choose: (CloudSaveCheck.Choice) -> Void
    let retry: () -> Void
    let cancel: () -> Void

    static let scope = "console.cloudSave"
    /// The button the controller starts on: the cloud's save, or Try again.
    static func firstFocus(_ question: CloudSaveQuestion) -> String { question.outcome == .unreadable ? "console.cloudSave.retry" : "console.cloudSave.cloud" }

    private func t(_ key: String) -> String { L10n.string(key, lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            Text(question.gameName).font(.manrope(compact ? 19 : 24, .semibold)).foregroundStyle(LauncherPalette.cream)
            if question.outcome == .unreadable {
                note(String(format: t("cloudCheck.unreadable.note"), question.gameName))
                if let reason = question.reason { Text(reason).font(.manrope(compact ? 14 : 17)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                button("arrow.clockwise", t("cloudCheck.retry"), t("cloudCheck.retry.detail"), id: "console.cloudSave.retry", primary: true, action: retry)
                button("desktopcomputer", t("cloudCheck.playLocal"), t("cloudCheck.playLocal.detail"), id: "console.cloudSave.offline") { choose(.offline) }
            } else {
                note(t("cloudCheck.differ.note"))
                button("icloud", t("cloudCheck.useCloud"), CloudSaveText.cloudDetail(question, t, lang: lang.code), id: "console.cloudSave.cloud", primary: true) { choose(.cloud) }
                button("desktopcomputer", t("cloudCheck.useLocal"), CloudSaveText.localDetail(question, t, lang: lang.code), id: "console.cloudSave.local") { choose(.local) }
                Text(t("cloudCheck.kept")).font(.manrope(compact ? 14 : 17)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action: cancel) {
                Text(t("cloudCheck.cancel")).font(.manrope(21, .semibold)).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 60).background(.white.opacity(0.08), in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain).padTarget("console.cloudSave.cancel", scope: Self.scope, radius: 32, activate: cancel)
        }
        .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.manrope(compact ? 18 : 22)).fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ symbol: String, _ title: String, _ detail: String, id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: compact ? 22 : 26, weight: .medium)).frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.manrope(compact ? 19 : 23, .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.manrope(compact ? 14 : 17)).opacity(0.75).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(primary ? LauncherPalette.background : .white)
            .padding(.horizontal, 22).padding(.vertical, compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary ? LauncherPalette.cream : LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).padTarget(id, scope: Self.scope, radius: 16, activate: action)
        .accessibilityLabel(title).accessibilityHint(detail)
    }
}
