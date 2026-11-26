import AppKit
import SwiftUI
import NXCore
import NXModel

/// An app nxkit built without a game profile (NxkitBuildProfile, v0lumehi/nxkit#54): it may start and then hang or render wrong, so the
/// game's page says so in a quiet row on the notice's surface (DSNotice), the same surface as NxkitFeedbackRow, with the detected engine
/// and graphics API when nxkit found them. Report opens a prefilled new issue in v0lumehi/nxkit in the browser, nothing is sent. The row
/// stays as long as the app is the generic build: it has no dismiss.
package struct NxkitGenericBuildRow: View {
    package init(profile: NxkitBuildProfile, reportURL: URL, scope: String = "main",
                 open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.init(profile: profile, scope: scope, open: open) { reportURL }
    }

    package init(profile: NxkitBuildProfile, scope: String = "main",
                 open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                 makeReportURL: @escaping () -> URL) {
        self.profile = profile; self.makeReportURL = makeReportURL; self.scope = scope; self.open = open
    }

    let profile: NxkitBuildProfile
    let makeReportURL: () -> URL
    let scope: String
    let open: (URL) -> Void
    @EnvironmentObject private var loc: Localizer

    /// "Engine: Unreal Engine · Graphics: Vulkan", empty when nxkit found neither.
    package static func detected(_ profile: NxkitBuildProfile, _ t: (String) -> String) -> String {
        [profile.engineName.map { String(format: t("nxkit.generic.engine"), $0) },
         profile.graphicsName.map { String(format: t("nxkit.generic.graphics"), $0) }]
            .compactMap { $0 }.joined(separator: " \u{00b7} ")
    }

    private func report() { open(makeReportURL()) }

    package var body: some View {
        let detected = Self.detected(profile, loc.t)
        HStack(spacing: 12) {
            Image(systemName: DSTone.warning.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(DSTone.warning.color)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("nxkit.generic.title")).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(loc.t("nxkit.generic.note")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !detected.isEmpty {
                    Text(detected).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                        .accessibilityIdentifier("nxkit.generic.detected")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(loc.t("nxkit.feedback.report"), action: report)
                .buttonStyle(LauncherSecondaryButtonStyle(height: 30)).fixedSize()
                .help(loc.t("nxkit.feedback.sendHelp"))
                .accessibilityIdentifier("nxkit.generic.report")
                .padTarget("nxkit.generic.report", scope: scope, activate: report)
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
        .frame(minHeight: LauncherNoticeStyle.minHeight)
        .background(LauncherNoticeStyle.fill, in: RoundedRectangle(cornerRadius: LauncherNoticeStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: LauncherNoticeStyle.radius).strokeBorder(LauncherPalette.cardBorder))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nxkit.generic")
    }
}
