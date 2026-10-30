import Foundation

/// The host layer's own words, from `Resources/Localizable.xcstrings` (English source, like ShellUI).
func hostText(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// Why a game cannot be shown as playable: `reason` is the short line under the title, `detail` the sentence for the
/// How to fix sheet. Both are already localized.
public struct GameProblem: Error, Equatable, Sendable, LocalizedError {
    public var reason: String
    public var detail: String
    public init(reason: String, detail: String = "") { self.reason = reason; self.detail = detail }
    public var errorDescription: String? { detail.isEmpty ? reason : "\(reason): \(detail)" }
}
