import GameController
import SwiftUI
import NXCore
import NXLauncher

/// The controller layouts of the Controls page (#70). Each produces only a DM_PAD_MAP value (dm/host/input_map.h), so the
/// host is unchanged: Standard passes nothing, By label one swap, Custom the buttons set by hand, and Auto picks Standard or
/// By label from the controller connected when Play is pressed.
enum PadMode: String, CaseIterable {
    case auto, standard, byLabel, custom
}

extension ControlLayout {
    /// By label, as one swap of the host's mapping. The host reads GameController's face buttons by position, in the
    /// Nintendo layout (front_mac.m pad_read: buttonB, on the right of Apple's diamond, is the Switch's A; buttonA, at the
    /// bottom, its B; buttonY, at the top, X; buttonX, on the left, Y). An Xbox controller's printed letters are Apple's
    /// diamond, so its A arrives as buttonA and reaches the game as B. A Nintendo controller arrives by its letters too: a
    /// real Pro Controller's A, on the right, arrives as buttonA (seedds/nxnative#382), so it also reaches the game as B. In
    /// both families the button printed A arrives as buttonA, B as buttonB, X as buttonX, Y as buttonY, and the same swap
    /// gives each its letter. For a Nintendo controller that is also its position, since its letters are the Switch's.
    static let byLabelPad = ["A": "B", "B": "A", "X": "Y", "Y": "X"]

    /// What each button sends in a layout (only the buttons that send another); Auto resolves to Standard or By label.
    func padMap(for mode: PadMode, category: String?) -> [String: String] {
        switch mode {
        case .standard: return [:]
        case .byLabel: return Self.byLabelPad
        case .custom: return pad
        case .auto: return padMap(for: Self.autoMode(category: category), category: nil)
        }
    }

    /// Auto's choice: By label for a Nintendo or an Xbox controller (GCController.productCategory: "Switch Pro Controller",
    /// "Nintendo Switch JoyCon (L/R)", "Xbox One", …), Standard for every other one and when none is connected. Matched by
    /// parts of the name, as the categories differ between controllers and macOS versions (JoyCon, Joy-Con).
    static func autoMode(category: String?) -> PadMode {
        guard let c = category?.lowercased().replacingOccurrences(of: "-", with: "") else { return .standard }
        return ["nintendo", "switch pro", "joycon", "xbox"].contains(where: c.contains) ? .byLabel : .standard
    }

    /// The controller a game started now would get: the one used last, else the first one connected.
    static func connectedCategory() -> String? {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        let current = GCController.current.flatMap { c in pads.contains(c) ? c : nil }
        return (current ?? pads.first)?.productCategory
    }
}

/// The Controls page's layout choice: a picker, which controller is connected and what Auto picks for it, and a note
/// on the layout chosen.
struct PadModeSection: View {
    @ObservedObject var m: BuildModel
    @ObservedObject var layout: ControlLayout
    @State private var category: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.t("controls.mode")).font(.manrope(15, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.t("controls.modeRow")).font(.manrope(14, .medium))
                    Text(connected).font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                LauncherDropdown(options: PadMode.allCases.map { (value: $0.rawValue, label: label($0)) },
                                 selection: layout.padMode.rawValue, label: m.t("controls.modeRow"), fill: true) { v in PadMode(rawValue: v).map(layout.setPadMode) }
                    .frame(width: 168)   // as wide as the button rows' choices below it
                    .frame(width: LaunchControl.width, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .frame(minHeight: 46)
            .padTarget("pad.mode", scope: "controls", radius: 10, activate: { step(1) }, adjust: step)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
            Text(m.t("controls.modeNote." + layout.padMode.rawValue)).font(.manrope(12)).foregroundStyle(.secondary)
                .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { category = layout.controllerCategory() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect).merge(with: NotificationCenter.default.publisher(for: .GCControllerDidDisconnect))) { _ in
            category = layout.controllerCategory()
            layout.objectWillChange.send()   // Auto's buttons below follow the controller
        }
    }

    private func label(_ mode: PadMode) -> String { m.t("controls.mode." + mode.rawValue) }

    private var connected: String {
        let pick = label(ControlLayout.autoMode(category: category))
        return category.map { String(format: m.t("controls.connected"), $0, pick) } ?? String(format: m.t("controls.noController"), pick)
    }

    /// A controller's left / right through the layouts.
    private func step(_ by: Int) {
        let all = PadMode.allCases
        let at = all.firstIndex(of: layout.padMode) ?? 0
        layout.setPadMode(all[(at + by + all.count) % all.count])
    }
}
