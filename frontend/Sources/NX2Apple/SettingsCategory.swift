import SwiftUI

/// The four parts of the Settings page (#678), in the order the selector shows them. One is visible at a time, each keeps its own
/// scroll position (ScrollMemory), and General is where it opens.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, library, controls, tools
    var id: String { rawValue }
    var labelKey: String { "settings.cat." + rawValue }
}
