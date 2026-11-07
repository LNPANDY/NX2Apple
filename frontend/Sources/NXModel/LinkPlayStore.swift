import Combine
import Foundation
import NXCore

/// Per-title LDN options. A saved choice affects the next launch, including Finder launches.
@MainActor package final class LinkPlayStore: ObservableObject {
    @Published package var config: LinkPlayConfiguration
    @Published package private(set) var error: String?
    @Published package private(set) var saved = false

    private let settings: GameLinkPlaySettings

    package init(titleID: String, appPath: String, support: URL? = nil) {
        settings = GameLinkPlaySettings(titleID: titleID, appPath: appPath, support: support)
        config = settings.load()
    }

    package func edited() { saved = false; error = nil }

    package func save() {
        do {
            try settings.save(config)
            error = nil
            saved = true
        } catch {
            self.error = error.localizedDescription
            saved = false
        }
    }

    package func reload() {
        config = settings.load()
        error = nil
        saved = false
    }
}
