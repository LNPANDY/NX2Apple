import Combine
import SwiftUI
import NXCore
import NXModel

/// The build log, right under the Mac / iPhone choice and folded away until it is asked for.
/// It used to sit at the bottom of the progress card, which is where a failed build's message
/// pointed ("see the log below") while the log itself was out of view on a short window (#52).
/// Observes the device store (for the note about the data transfer) and, through `BuildLogView`, the log.
package struct LogCard: View {
    let log: BuildLog
    @ObservedObject var devices: DeviceStore
    /// A request to open the log (a clicked notification of a failed build). `didShow` tells the sender it was taken.
    let showRequests: AnyPublisher<Bool, Never>
    let didShow: () -> Void
    @EnvironmentObject var loc: Localizer
    @Binding var logOpen: Bool   // kept by the page, so the log stays open when the page is left and back

    package init(log: BuildLog, devices: DeviceStore, isOpen: Binding<Bool>, showRequests: AnyPublisher<Bool, Never>, didShow: @escaping () -> Void) {
        self.log = log
        self.devices = devices
        _logOpen = isOpen
        self.showRequests = showRequests
        self.didShow = didShow
    }

    package var body: some View {
        CardGroup(loc.t("section.log")) {
            if devices.shellCopy != nil || devices.shellWaiting {
                // The log below is the build's own output; the data transfer is driven by the app, so
                // its questions and errors (a locked device, a failed listing) answer here, not in it.
                Text(loc.t("log.transferNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.top, 2)
            }
            CardDisclosure(loc.t("build.log"), isOpen: logOpen) { logOpen.toggle() }
            if logOpen { BuildLogView(log: log, placeholder: loc.t("log.placeholder")).padding(.horizontal, 14).padding(.bottom, 14) }
        }
        .onReceive(showRequests) { show in
            if show { logOpen = true; DispatchQueue.main.async { didShow() } }
        }
    }
}
