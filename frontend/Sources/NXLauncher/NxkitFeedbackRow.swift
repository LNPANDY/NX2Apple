import AppKit
import SwiftUI
import NXCore
import NXModel

/// "Did it work?" after an nxkit (Beta) build and after the first start of its app (LNPANDY/NX2Apple#1460): a quiet row on the notice's surface
/// (DSNotice), thumbs up and thumbs down, and a dismiss. Thumbs up opens a report "Works", thumbs down asks once between "Problems" and "Does not
/// start". A failed build has one Report button, "Does not start". The answer opens a prefilled new issue in v0lumehi/nxkit in the browser, nothing is sent.
package struct NxkitFeedbackRow: View {
    package init(prompt: NxkitFeedbackPrompt, scope: String = "main", open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                 done: @escaping () -> Void) {
        self.prompt = prompt; self.scope = scope; self.open = open; self.done = done
    }
    let prompt: NxkitFeedbackPrompt
    let scope: String
    let open: (URL) -> Void
    /// Answered or dismissed: the store marks the question asked.
    let done: () -> Void
    @State private var which = false
    @EnvironmentObject private var loc: Localizer

    private var title: String {
        if which { return loc.t("nxkit.feedback.which") }
        return loc.t(prompt.moment == .failed ? "nxkit.feedback.failedTitle" : "nxkit.feedback.title")
    }

    private var detail: String {
        switch prompt.moment {
        case .built: return String(format: loc.t("nxkit.feedback.built"), prompt.gameName)
        case .failed: return String(format: loc.t("nxkit.feedback.failed"), prompt.gameName)
        case .firstLaunch: return String(format: loc.t("nxkit.feedback.launched"), prompt.gameName)
        }
    }

    private func answer(_ result: NxkitFeedback.Result) {
        open(NxkitFeedback.issueURL(prompt.report(result)))
        done()
    }

    private func thumbsDown() { which = true }

    package var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DSTone.info.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(DSTone.info.color)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if prompt.moment == .failed {
                // a build that stopped did not work: one action, the report "Does not start" with the exit code and the last lines
                Button(loc.t("nxkit.feedback.report")) { answer(.doesNotStart) }
                    .buttonStyle(LauncherSecondaryButtonStyle(height: 30)).fixedSize()
                    .padTarget("nxkit.feedback.report", scope: scope) { answer(.doesNotStart) }
            } else if which {
                Button(loc.t("nxkit.feedback.problems")) { answer(.problems) }
                    .buttonStyle(LauncherSecondaryButtonStyle(height: 30)).fixedSize()
                    .padTarget("nxkit.feedback.problems", scope: scope) { answer(.problems) }
                Button(loc.t("nxkit.feedback.doesNotStart")) { answer(.doesNotStart) }
                    .buttonStyle(LauncherSecondaryButtonStyle(height: 30)).fixedSize()
                    .padTarget("nxkit.feedback.doesNotStart", scope: scope) { answer(.doesNotStart) }
            } else {
                Button { answer(.works) } label: { Image(systemName: "hand.thumbsup") }
                    .buttonStyle(LauncherIconButtonStyle(size: 28))
                    .help(loc.t("nxkit.feedback.yes")).accessibilityLabel(loc.t("nxkit.feedback.yes"))
                    .accessibilityIdentifier("nxkit.feedback.yes")
                    .padTarget("nxkit.feedback.yes", scope: scope, radius: 14) { answer(.works) }
                Button(action: thumbsDown) { Image(systemName: "hand.thumbsdown") }
                    .buttonStyle(LauncherIconButtonStyle(size: 28))
                    .help(loc.t("nxkit.feedback.no")).accessibilityLabel(loc.t("nxkit.feedback.no"))
                    .accessibilityIdentifier("nxkit.feedback.no")
                    .padTarget("nxkit.feedback.no", scope: scope, radius: 14, activate: thumbsDown)
            }
            Button(action: done) { Image(systemName: "xmark") }
                .buttonStyle(LauncherIconButtonStyle(size: 28))
                .help(loc.t("nxkit.feedback.dismiss")).accessibilityLabel(loc.t("nxkit.feedback.dismiss"))
                .accessibilityIdentifier("nxkit.feedback.dismiss")
                .padTarget("nxkit.feedback.dismiss", scope: scope, radius: 14, activate: done)
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
        .frame(minHeight: LauncherNoticeStyle.minHeight)
        .background(LauncherNoticeStyle.fill, in: RoundedRectangle(cornerRadius: LauncherNoticeStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: LauncherNoticeStyle.radius).strokeBorder(LauncherPalette.cardBorder))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nxkit.feedback")
    }
}
