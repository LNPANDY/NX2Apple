import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The layout editor's state while it is open (#414): which layout, which control is chosen, whether a controller holds it, and the
/// feedback of the last move. Changes stay in this draft until the player confirms. The editor session owner keeps this model alive
/// while the displayed game surface changes size or pose.
@MainActor @Observable final class TouchLayoutEditorModel {
    typealias Control = TouchLayout.Control

    @ObservationIgnored let store: ShellSettingsStore
    /// The device held sideways, and upright where the controls can sit below the picture (an iPad, iPhone Duo), else nil.
    let sideways: PadScreen
    let upright: PadScreen?
    private let initialLayout: TouchLayout
    private let initialSize: String
    private let initialStick: String
    private let initialFull: Bool
    var confirmingExit = false
    private(set) var editing: TouchLayoutEditing
    /// The control the arrows and VoiceOver's actions move.
    var selected: Control?
    /// A controller or keyboard holds the selected control: the D-pad moves it, A or B puts it down.
    private(set) var held = false
    /// Counts the kept steps and the rejected spots, for the haptics.
    private(set) var stepCount = 0
    private(set) var rejectCount = 0
    /// The last move had no room: the line under the preview says so until the next move.
    private(set) var rejected = false
    /// A touch drag is currently showing a rejected position; Save waits until the finger is released.
    private(set) var invalidPlacement = false
    /// Reset all was asked for and waits for its answer: the editor asks before it puts every control of the shown layout back.
    private(set) var confirmingReset = false

    init(store: ShellSettingsStore = .current, sideways: PadScreen = .proMax, upright: PadScreen? = nil, kind: TouchLayout.Kind? = nil) {
        self.store = store
        initialLayout = store.touchLayout
        initialSize = store.touchSize
        initialStick = store.touchStick
        self.sideways = sideways
        self.upright = upright
        let kind = kind ?? .of(full: store.touchMode == "3d", split: false)
        initialFull = kind.full
        let k = upright == nil && kind.split ? TouchLayout.Kind.of(full: kind.full, split: false) : kind
        editing = TouchLayoutEditing(layout: store.touchLayout, kind: k, screen: k.split ? (upright ?? sideways) : sideways,
                                     size: store.touchSize, stick: store.touchStick)
    }

    var hasChanges: Bool {
        editing.layout != initialLayout || editing.size != initialSize || editing.stick != initialStick || editing.kind.full != initialFull
    }
    func requestExit() -> Bool {
        confirmingExit = hasChanges
        return !hasChanges
    }

    var kind: TouchLayout.Kind { editing.kind }
    var geo: PadGeo { editing.geo }
    var together: Bool { editing.together }
    var layoutIsBuiltIn: Bool { editing.layout.isEmpty(editing.kind) }

    /// The live game surface supplied by the in-context editor. The legacy sideways/upright pair remains the initial fallback for
    /// settings previews and captures; once a live surface arrives it owns the active geometry and split-layout choice.
    private(set) var actualScreen: PadScreen?

    /// Rebase the draft's geometry on the current game surface. A split layout is available whenever the engine geometry separates
    /// gameplay and controls; device identity is deliberately not part of this decision. Keep the complete layout object untouched:
    /// offsets for other layouts may not fit this surface, but are still valid saved preferences for those layouts.
    func updateScreen(_ screen: PadScreen) {
        guard screen.size.width.isFinite, screen.size.height.isFinite,
              screen.size.width > 0, screen.size.height > 0 else { return }

        let split = PadGeo.region(screen).separated
        let nextKind = TouchLayout.Kind.of(full: editing.kind.full, split: split)
        guard actualScreen != screen || editing.screen != screen || editing.kind != nextKind else { return }

        actualScreen = screen
        editing.screen = screen
        editing.kind = nextKind
        if let selected, !selected.drawn(full: nextKind.full) { self.selected = nil }
        held = false
        rejected = false
        invalidPlacement = false
        confirmingReset = false
    }

    func setKind(_ kind: TouchLayout.Kind) {
        let nextKind: TouchLayout.Kind
        if let actualScreen {
            nextKind = .of(full: kind.full, split: PadGeo.region(actualScreen).separated)
        } else {
            guard !kind.split || upright != nil else { return }
            nextKind = kind
        }
        guard nextKind != editing.kind else { return }
        editing.kind = nextKind
        if actualScreen == nil {
            editing.screen = nextKind.split ? (upright ?? sideways) : sideways
        }
        if let s = selected, !s.drawn(full: nextKind.full) { selected = nil }
        held = false; rejected = false; invalidPlacement = false; confirmingReset = false
    }
    func setSize(_ size: String) {
        guard ShellSettingsStore.touchSizes.contains(size) else { return }
        editing.size = size
        held = false; rejected = false; invalidPlacement = false
    }
    func setStick(_ stick: String) {
        guard ShellSettingsStore.touchStickPlaces.contains(stick) else { return }
        editing.stick = stick
        held = false; rejected = false; invalidPlacement = false
    }

    func setTogether(_ on: Bool) {
        editing.together = on
        if !on, selected == .face { selected = .a }
        held = false
        rejected = false
        invalidPlacement = false
    }

    func select(_ c: Control?) {
        selected = c
        rejected = false
        invalidPlacement = false
        if c == nil { held = false }
    }
    /// A controller's A on a control: it is held until A or B puts it down.
    func pickUp(_ c: Control) { selected = c; held = true; rejected = false; invalidPlacement = false }
    func putDown() { held = false; invalidPlacement = false }

    /// One step of the chosen control. Reports the outcome for VoiceOver.
    @discardableResult func nudge(dx: Int, dy: Int) -> TouchLayoutEditing.Outcome? {
        guard let c = selected else { return nil }
        let outcome = editing.nudge(c, dx: dx, dy: dy)
        switch outcome {
        case .moved: stepCount += 1; rejected = false
        case .rejected: rejectCount += 1; rejected = true
        case .atEdge: rejectCount += 1; rejected = false
        }
        return outcome
    }
    func nudge(_ action: ShellInput.Action) {
        switch action {
        case .left: nudge(dx: -1, dy: 0)
        case .right: nudge(dx: 1, dy: 0)
        case .up: nudge(dx: 0, dy: -1)
        case .down: nudge(dx: 0, dy: 1)
        default: break
        }
    }

    /// A drag: the offset of the control it holds, as asked so far. Kept spots are drawn at once and held in the draft.
    func dragOffset(_ c: Control) -> TouchLayout.Offset { editing.offset(editing.mover(c)) }
    func dragTo(_ c: Control, from start: TouchLayout.Offset, by translation: CGSize) -> (offset: TouchLayout.Offset, kept: Bool) {
        let o = editing.dragged(from: start, by: translation)
        let before = editing.offset(editing.mover(c))
        let kept = editing.place(c, o)
        invalidPlacement = !kept
        if kept && editing.offset(editing.mover(c)) != before { stepCount += 1 }
        return (o, kept)
    }
    /// The end of a drag: a rejected spot sends the control back (the view animates it) and says so.
    func dragEnded(rejected spot: Bool) {
        invalidPlacement = false
        if spot { rejectCount += 1; rejected = true } else { rejected = false }
    }

    func putBack() {
        guard let c = selected else { return }
        editing.putBack(c)
        rejected = false
        invalidPlacement = false
    }
    /// Reset all: ask first. Nothing to reset asks nothing.
    func askReset() { if !layoutIsBuiltIn { confirmingReset = true } }
    func cancelReset() { confirmingReset = false }
    /// Every control of the shown layout back to its built-in place (the answer to askReset).
    func reset() {
        editing.reset()
        rejected = false
        invalidPlacement = false
        confirmingReset = false
    }

    /// Save presets and custom positions together; untouched layout variants remain in the draft.
    func commit() {
        store.storeTouchSize(editing.size)
        store.storeTouchStick(editing.stick)
        store.storeTouchLayout(editing.layout)
        if editing.kind.full != initialFull { store.storeTouchMode(editing.kind.full ? "3d" : "2d") }
    }
}

extension TouchLayoutEditorModel {
    /// Opens the saved global layout; live geometry decides the overlay/split variant.
    static func forDevice(window: CGSize, insets: EdgeInsets, store: ShellSettingsStore = .current) -> TouchLayoutEditorModel {
        #if os(iOS)
        let screens = TouchLayoutScreens.device(window: window, insets: insets, isPad: UIDevice.current.userInterfaceIdiom == .pad)
        #else
        let screens = (sideways: PadScreen.proMax, upright: PadScreen?.none)
        #endif
        return TouchLayoutEditorModel(store: store, sideways: screens.sideways, upright: screens.upright)
    }

    /// A change of one of the editor's rows from the list of choices (a row too narrow for its segments).
    func apply(row id: String, value: String) {
        switch id {
        case TouchLayoutEditorView.layoutRow: setKind(.of(full: value == "3d", split: kind.split))
        case TouchLayoutEditorView.poseRow: setKind(.of(full: kind.full, split: value == "below"))
        case TouchLayoutEditorView.togetherRow: setTogether(value == "1")
        default: break
        }
    }
}

/// The game's screen on this device, for the editor: the shell's window (on a phone the screen) held sideways, and upright where a
/// game puts the controls below the picture (an iPad, and a foldable's inner display, which is about 1.4 to 1 where a phone is above 2
/// to 1). The side insets of a phone held sideways are its top inset upright (the Dynamic Island or the notch), and the home indicator
/// takes 21 points. An approximation for the preview: the engine places the controls on the real screen.
enum TouchLayoutScreens {
    static func device(window: CGSize, insets: EdgeInsets, isPad: Bool) -> (sideways: PadScreen, upright: PadScreen?) {
        let long = max(window.width, window.height), short = min(window.width, window.height)
        guard long > 0, short > 0 else { return (.proMax, nil) }
        if isPad {
            let i = PadScreen.Insets(top: 24, bottom: 20)
            return (PadScreen(size: CGSize(width: long, height: short), insets: i), PadScreen(size: CGSize(width: short, height: long), insets: i))
        }
        let upright = window.height > window.width
        let island = upright ? insets.top : max(insets.leading, insets.trailing)
        let home: CGFloat = insets.bottom > 0 ? 21 : 0
        let side = island > 30 ? island : 0
        let sideways = PadScreen(size: CGSize(width: long, height: short), insets: PadScreen.Insets(left: side, bottom: home, right: side))
        guard long / short < 1.7 else { return (sideways, nil) }
        // A foldable's inner display upright: the fold across the middle, the picture above it keeps only the top inset.
        let fold = CGRect(x: 0, y: long / 2 - 20, width: short, height: 40)
        let top = upright ? insets.top : max(insets.leading, insets.trailing)
        return (sideways, PadScreen(size: CGSize(width: short, height: long), insets: PadScreen.Insets(top: top, bottom: insets.bottom > 0 ? 34 : 0),
                                    division: fold, topSafeOnly: true))
    }
}
