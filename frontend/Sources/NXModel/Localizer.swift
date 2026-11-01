import Foundation
import Combine
import NXCore

/// The interface language and the strings for it (LNPANDY/NX2Apple#387). Views take it from the environment, so a language change
/// redraws the views that show text and nothing else. `BuildModel` gets it through its init for the strings it writes itself.
///
/// The language choice is stored by `Lang.saved` (UserDefaults key `appLanguage`): "" follows the system. `choose()` writes it.
///
/// `lang` and `t()` are not tied to the main actor, because `BuildModel` writes status text from background queues. The value is
/// behind a lock, and a change sends `objectWillChange` for the views.
@MainActor package final class Localizer: ObservableObject {
    /// Holds the language where any thread may read it.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Lang
        init(_ lang: Lang) { stored = lang }
        var value: Lang {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private let box: Box
    nonisolated package let objectWillChange = ObservableObjectPublisher()

    nonisolated package init(_ lang: Lang = Lang.initial()) { box = Box(lang) }

    /// The interface language: the one picked in Settings, else the system's.
    nonisolated package var lang: Lang {
        get { box.value }
        set {
            guard newValue != box.value else { return }
            objectWillChange.send()
            box.value = newValue
        }
    }

    /// The string for `key` in the current language. An unknown key comes back as itself, so it shows up in the UI.
    nonisolated package func t(_ key: String) -> String { L10n.string(key, lang) }

    /// Settings' choice: "" follows the system, else a `Lang` raw value. It is stored, and the language changes now.
    package func choose(_ code: String) {
        Lang.saved = Lang(rawValue: code)
        lang = Lang.initial()
    }
}
