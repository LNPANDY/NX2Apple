import SwiftUI
import NXCore
import NXModel

/// The MacNativeGames recommendation on the Builds page (LNPANDY/NX2Apple#1473): the picked title is one of the five MacNativeGames
/// maintains and nxnative builds it. One notice (DSNotice) with one action: Switch to MacNativeGames, or Download & Switch while it
/// is not set up. While it is fetched the symbol is a spinner and the detail says how far it is. It is about the picked title, so it
/// sits with the files, not in Settings.
package struct MacNativeGamesNotice: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject private var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    /// Shown for a supported title under nxnative, and while MacNativeGames is fetched for it.
    package static func shows(_ build: BuildStore) -> Bool {
        build.shouldRecommendMacNativeGames
    }

    package var body: some View {
        if Self.shows(build) {
            let state = build.upstreamState(.macNativeGames)
            let title = loc.t(build.macNativeGamesInstalled ? "upstream.mngSwitchBtn" : "upstream.mngDownloadSwitchBtn")
            LauncherNotice(LauncherNoticeItem(id: "build.mngRecommend", tone: .info, title: loc.t("upstream.mngRecommendNote"),
                detail: state.isBusy ? UpstreamStatusText.busy(state, loc) : UpstreamStatusText.failure(state, loc),
                busy: state.isBusy,
                action: state.isBusy ? nil : .init(title: title, padID: "set.build.mngRecommend") { build.downloadAndSwitchToMacNativeGames() }),
                enabled: !build.running)
        }
    }
}

/// What an external engine's download says: its progress, the unpacking, why it failed. Shared by the Builds page's notice and
/// the engine rows in Settings.
package enum UpstreamStatusText {
    /// "Downloading… 12 MB of 40 MB" or "Unpacking…", nil when nothing runs.
    package static func busy(_ state: UpstreamInstallState, _ loc: Localizer) -> String? {
        switch state {
        case .downloading(_, let progressText):
            return progressText.isEmpty ? loc.t("upstream.downloading") : String(format: loc.t("upstream.downloadingProgress"), progressText)
        case .extracting:
            return loc.t("upstream.extracting")
        default:
            return nil
        }
    }

    /// Why the last download did not land, nil when it did not fail.
    package static func failure(_ state: UpstreamInstallState, _ loc: Localizer) -> String? {
        guard case .failed(let reason) = state else { return nil }
        return loc.t(reason == .download ? "upstream.downloadFailed" : "upstream.extractFailed")
    }
}
