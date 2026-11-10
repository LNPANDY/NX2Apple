import Foundation

/// The panels of the menu sheet that are drawn by flags (`controllersOpen`, `shellSettingsOpen`). When the last open panel closes, its flag goes
/// false at once and the sheet starts sliding out, and with the flag gone the sheet showed an empty page while it left, unlike Game settings (#664).
/// The closed panel stays drawn until the sheet is dismissed. It is only drawn: it takes no touch, no focus and no accessibility while it leaves.
/// A panel that closes while the sheet stays (Controllers closed from Game settings) is not retained, so it never covers what is under it.
struct PanelRetention: Equatable {
    enum Panel: Equatable { case controllers, shellSettings }
    private(set) var retained: Panel?

    /// A panel closed. `sheetStaysOpen`: another panel is still open, so nothing slides away.
    mutating func closed(_ panel: Panel, sheetStaysOpen: Bool) { retained = sheetStaysOpen ? nil : panel }

    /// The sheet is gone, or a panel opened again.
    mutating func reset() { retained = nil }

    /// Whether the panel is drawn: open, or sliding out with the sheet.
    func draws(_ panel: Panel, open: Bool) -> Bool { open || retained == panel }

    /// Drawn only because it is leaving: no interaction, hidden from VoiceOver and the controller's focus.
    func isLeaving(_ panel: Panel, open: Bool) -> Bool { !open && retained == panel }
}
