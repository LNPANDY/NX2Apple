import SwiftUI
import TipKit
#if os(iOS)
import UIKit
#endif

/// The touch controls' layout editor (#414), a screen of the shell settings: the controls of one layout drawn as the game draws them, on
/// this device's screen at its own proportions. Tap a control to select it, then drag it in a separate gesture; moves snap to steps
/// of a quarter key. Where it would cover another control or leave its area it turns red and goes back when let go. The allowed area
/// shows while it is chosen. A chosen control also moves step by step with the arrows, a controller (A picks it up, the D-pad moves it,
/// A or B puts it down) or VoiceOver's actions.
/// Reset this control and Reset all controls return one control or the whole shown layout to the built-in places, Reset all after
/// a question. The engine places every control again on the
/// device, so nothing the editor stores can break a game's layout.
struct TouchLayoutEditorView: View {
    @Bindable var model: TouchLayoutEditorModel
    var close: () -> Void
    var cancel: (() -> Void)? = nil
    @Environment(\.shellDismissTouchEditor) private var dismissEditor
#if os(iOS)
    @State private var liveGeometry: TouchLayoutGeometrySnapshot?
    /// Ordinary phones play sideways; while the shell remains upright, this is a scaled landscape fallback.
    @State private var phonePortraitFallback = false
#endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The system's echo of a controller button: the editor's buttons do nothing for it (the shell's focus took it).
    @Environment(\.shellIgnoresPress) private var ignoresPress
    @Environment(\.scenePhase) private var scenePhase
    @State private var idleActivity = 0
    /// The drag in progress: the control, where its offset started, and the spot drawn under the finger when the engine refuses it.
    @State private var drag: DragState?
    @State private var bounce: CGSize = .zero
    @State private var optionsPresented = false
    @State private var hintVisible = true
    @State private var editorTip = TouchEditorTip()
    @State private var hintHeight: CGFloat = 80

    private struct DragState: Equatable {
        var control: TouchLayout.Control
        var start: TouchLayout.Offset
        var refused: TouchLayout.Offset?
    }

    static let arrowSize: CGFloat = 48

    var body: some View {
        GeometryReader { proxy in
            let contentInsets = proxy.safeAreaInsets
            let windowSize = CGSize(width: proxy.size.width + contentInsets.leading + contentInsets.trailing,
                                    height: proxy.size.height + contentInsets.top + contentInsets.bottom)
#if os(iOS)
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            // Size from the current container; feeding the last probe size back can pin the old orientation.
            let canvasSize = windowSize
#else
            let division = reservedDivision(in: proxy)?.offsetBy(dx: contentInsets.leading, dy: contentInsets.top)
            let actualScreen = TouchLayoutGeometrySnapshot(bounds: CGRect(origin: .zero, size: windowSize),
                safeAreaInsets: .init(top: contentInsets.top, left: contentInsets.leading, bottom: contentInsets.bottom, right: contentInsets.trailing),
                division: division, hingeStatus: nil).screen
            let canvasSize = windowSize
#endif
            ZStack(alignment: .topLeading) {
                ShellPalette.background.ignoresSafeArea()
                canvas
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .offset(x: -contentInsets.leading, y: -contentInsets.top)
#if os(iOS)
                    .allowsHitTesting(liveGeometry != nil)
#endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(iOS)
            .background {
                TouchLayoutGeometryProbe { liveGeometry = $0 }
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .onChange(of: liveGeometry, initial: true) { _, geometry in
                guard let geometry else { return }
                let context = Self.editorContext(geometry: geometry, isPad: isPad)
                phonePortraitFallback = context.phonePortraitFallback
                model.updateScreen(context.screen)
                drag = nil
                bounce = .zero
            }
#else
            .onChange(of: actualScreen, initial: true) { _, newScreen in
                model.updateScreen(newScreen)
                drag = nil
                bounce = .zero
            }
#endif
        }
        .simultaneousGesture(TapGesture().onEnded { hintVisible = false; idleActivity &+= 1 })
        .task { try? Tips.configure([.displayFrequency(.immediate)]) }
        .accessibilityIdentifier("touchLayout.editor")
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onChange(of: model.stepCount) { _, _ in if drag == nil { idleActivity &+= 1 } }
        .onChange(of: model.selected) { _, _ in idleActivity &+= 1 }
        .sensoryFeedback(.selection, trigger: model.stepCount)
        .sensoryFeedback(.warning, trigger: model.rejectCount)
        .confirmationDialog(ShellStrings.text("Discard changes?"), isPresented: $model.confirmingExit, titleVisibility: .visible) {
            Button(ShellStrings.text("Discard changes"), role: .destructive, action: discardAndClose)
                .accessibilityIdentifier("touchLayout.discard")
            Button(ShellStrings.text("Keep editing"), role: .cancel) { }
                .accessibilityIdentifier("touchLayout.keepEditing")
        } message: {
            Text(ShellStrings.text("Your changes will be lost."))
        }
    }

    private var exactGeometryReady: Bool {
        #if os(iOS)
        liveGeometry != nil && !phonePortraitFallback
        #else
        true
        #endif
    }

    private func requestExit() {
        guard !ignoresPress() else { return }
        if model.requestExit() { discardAndClose() }
    }

    private func discardAndClose() {
        guard !ignoresPress() else { return }
        (cancel ?? close)()
        dismissEditor?()
    }

    private func saveAndClose() {
        guard !ignoresPress(), !model.invalidPlacement, exactGeometryReady else { return }
        close()
        dismissEditor?()
    }

    private var editorCancelButton: some View {
        Button(action: requestExit) {
            Label(ShellStrings.text("Exit"), systemImage: "xmark")
        }
        .buttonStyle(.glass)
        .accessibilityLabel(ShellStrings.text("Exit"))
        .accessibilityIdentifier("touchLayout.back")
        .shellTarget("lay.back", action: requestExit)
    }

    private var editorOptionsButton: some View {
        Button { if !ignoresPress() { hintVisible = false; optionsPresented = true } } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .frame(width: 44, height: 44)
        .accessibilityLabel(ShellStrings.text("Touch controls options"))
        .accessibilityIdentifier("touchLayout.options")
        .shellTarget("lay.options") { hintVisible = false; optionsPresented = true }
        .popover(isPresented: $optionsPresented, attachmentAnchor: .rect(.bounds)) {
            optionsPopover
                .frame(width: 320)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var editorDoneButton: some View {
        Button(action: saveAndClose) {
            Label(ShellStrings.text("Save"), systemImage: "checkmark")
        }
        .buttonStyle(.glassProminent)
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(ShellPalette.cream)
        .foregroundStyle(.black)
        .disabled(model.invalidPlacement || !exactGeometryReady)
        .accessibilityLabel(ShellStrings.text("Save"))
        .accessibilityIdentifier("touchLayout.done")
        .shellTarget("lay.done", enabled: !model.invalidPlacement && exactGeometryReady) {
            saveAndClose()
        }
    }

    private func reservedDivision(in proxy: GeometryProxy) -> CGRect? {
        #if os(iOS)
        if #available(iOS 27.1, *) { return proxy.reservedRegions(kind: .division).first?.frame }
        #endif
        return nil
    }

    struct EditorContext {
        var screen: PadScreen
        var phonePortraitFallback: Bool
    }

    static func editorContext(geometry: TouchLayoutGeometrySnapshot, isPad: Bool) -> EditorContext {
        let screen = geometry.screen
        let hingeKnown = geometry.hingeStatus.map { $0 != .unknown } ?? false
        let foldContext = geometry.hingeStatus != .closed && (hingeKnown || geometry.division != nil)
        let portraitPhone = !isPad && screen.size.height > screen.size.width && !foldContext
        guard portraitPhone else { return EditorContext(screen: screen, phonePortraitFallback: false) }

        let insets = EdgeInsets(top: geometry.safeAreaInsets.top, leading: geometry.safeAreaInsets.left,
                                bottom: geometry.safeAreaInsets.bottom, trailing: geometry.safeAreaInsets.right)
        let fallback = TouchLayoutScreens.device(window: geometry.bounds.size, insets: insets, isPad: false).sideways
        return EditorContext(screen: fallback, phonePortraitFallback: true)
    }

    private var liveHingeStatus: TouchLayoutGeometrySnapshot.HingeStatus? {
        #if os(iOS)
        liveGeometry?.hingeStatus
        #else
        nil
        #endif
    }

    static func layoutTitle(screen: PadScreen, hingeStatus: TouchLayoutGeometrySnapshot.HingeStatus?) -> String {
        if screen.size.height > screen.size.width { return ShellStrings.text("Portrait") }
        return ShellStrings.text(hingeStatus == .closed ? "Landscape (Duo outer screen)" : "Landscape")
    }

    private var optionsPopover: some View {
        VStack(spacing: 0) {
            HStack {
                editorCancelButton
                Spacer()
                editorDoneButton
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Self.layoutTitle(screen: screen, hingeStatus: liveHingeStatus)).font(.headline)
                        .accessibilityIdentifier("touchLayout.orientation")
                    Text(ShellStrings.text(model.kind.split ? "Positions are saved for portrait and tabletop controls." : "Positions are shared across landscape views."))
                        .font(.footnote).foregroundStyle(.secondary)
                    NativeChoiceControl(row: sizeRow, targetPrefix: "lay.row.") { model.setSize($0) }
                    NativeChoiceControl(row: layoutChoiceRow, targetPrefix: "lay.row.") { value in
                        model.setKind(.of(full: value == "3d", split: model.kind.split))
                    }
                    TouchControlsNote()
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealHeight: 340)
            .accessibilityIdentifier("touchLayout.options.scroll")
        }
        .frame(maxWidth: 320)
    }

    private var sizeRow: SettingRow {
        var row = ShellSettingsRows.touchSizeRow(model.store)
        row.value = model.editing.size
        return row
    }

    private var layoutChoiceRow: SettingRow {
        SettingRow(id: Self.layoutRow, label: ShellStrings.text("Layout"),
                   kind: .choice([SettingOption("2d", "2D"), SettingOption("3d", "3D")]),
                   value: model.kind.full ? "3d" : "2d")
    }

    /// The rows report to the editor, not to a game or the shell settings (LibraryView.pickChoice).
    static let gameID = "touchLayout"
    static let layoutRow = "lay.layout", poseRow = "lay.pose", togetherRow = "lay.together"

    // MARK: The preview

    private var screen: PadScreen { model.editing.screen }

    private var canvas: some View {
        let g = model.geo
        let active = drag?.control ?? model.selected
        return GeometryReader { proxy in
            let k = proxy.size.width / screen.size.width
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(selectionTapGesture(k: k))
                    .simultaneousGesture(dragGesture(k: k))
                Canvas { context, _ in
                    context.scaleBy(x: k, y: k)
                    drawBackdrop(g, in: &context)
                    if let active { drawGuides(for: active, g, k: k, in: &context) }
                    for c in g.drawnControls where !isActive(c, active) { draw(c, g, k: k, in: &context) }
                }
                .allowsHitTesting(false)
                if let active {
                    Canvas { context, _ in
                        context.scaleBy(x: k, y: k)
                        for c in g.drawnControls where isActive(c, active) { draw(c, g, k: k, highlight: drag?.refused == nil ? .chosen : .refused, in: &context) }
                    }
                    .offset(x: activeOffset(g).width * k, y: activeOffset(g).height * k)
                    .allowsHitTesting(false)
                }
                accessibilityElements(g, k: k)
                TouchEditorCogHalo(active: exactGeometryReady && scenePhase == .active && drag == nil && !model.held && !optionsPresented && !model.confirmingExit,
                                   activity: idleActivity)
                    .allowsHitTesting(false)
                    .position(x: g.swap.x * k, y: g.swap.y * k)
                editorOptionsButton.position(x: g.swap.x * k, y: g.swap.y * k)
                if hintVisible && exactGeometryReady {
                    TipView(editorTip, arrowEdge: .top)
                        .accessibilityIdentifier("touchLayout.tip")
                        .frame(width: min(280, proxy.size.width - 32))
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hintHeight = $0 }
                        .position(x: g.swap.x * k, y: min(g.swap.y * k + 30 + hintHeight / 2, proxy.size.height - hintHeight / 2 - 16))
                }
                if drag == nil, let selected = model.selected,
                   let box = g.box(of: model.editing.mover(selected))?.box,
                   let bounds = g.box(of: model.editing.mover(selected))?.within {
                    selectedToolbar(for: selected)
                        .position(selectionToolsPosition(for: selected, box: box, bounds: bounds, canvasSize: proxy.size, scale: k))
                }
            }
        }
        .aspectRatio(screen.size.width / screen.size.height, contentMode: .fit)
        .background(PadDrawing.backdrop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ShellStrings.text("Preview of the touch controls"))
        .accessibilityIdentifier("touchLayout.preview")
    }

    private func selectionToolsPosition(for selected: TouchLayout.Control, box: CGRect, bounds: CGRect,
                                        canvasSize: CGSize, scale: CGFloat) -> CGPoint {
        var bounds = bounds
        if let division = screen.division, division.height > division.width, division.intersects(bounds) {
            if box.midX < division.midX {
                bounds.size.width = max(0, min(bounds.maxX, division.minX) - bounds.minX)
            } else {
                let right = bounds.maxX
                bounds.origin.x = max(bounds.minX, division.maxX)
                bounds.size.width = max(0, right - bounds.minX)
            }
        }
        let toolbarWidth = selectedToolbarWidth(for: selected)
        let halfWidth = toolbarWidth / 2, halfHeight = 30.0
        let minX = bounds.minX * scale + halfWidth, maxX = bounds.maxX * scale - halfWidth
        let minY = bounds.minY * scale + halfHeight, maxY = bounds.maxY * scale - halfHeight
        let x = minX <= maxX ? min(max(box.midX * scale, minX), maxX) : bounds.midX * scale
        let above = box.minY * scale - halfHeight - 8
        let below = box.maxY * scale + halfHeight + 8
        let y = minY <= maxY ? (above >= minY ? above : min(max(below, minY), maxY)) : bounds.midY * scale
        return CGPoint(x: min(max(x, halfWidth), canvasSize.width - halfWidth), y: min(max(y, halfHeight), canvasSize.height - halfHeight))
    }

    private func selectedToolbarWidth(for selected: TouchLayout.Control) -> CGFloat {
        let count: CGFloat = selected == .face || selected.isFaceKey ? 2 : 1
        return count * 44 + (count - 1) * 8 + 12
    }

    private func selectedToolbar(for selected: TouchLayout.Control) -> some View {
        GlassEffectContainer(spacing: 12) {
        HStack(spacing: 8) {
            selectedReset.labelStyle(.iconOnly).frame(width: 44, height: 44)

            if selected == .face || selected.isFaceKey {
                Toggle(isOn: Binding(get: { model.together }, set: { if !ignoresPress() { model.setTogether($0) } })) {
                    Image(systemName: "square.on.square.squareshape.controlhandles")
                        .foregroundStyle(model.together ? Color.black : Color.white)
                }
                .toggleStyle(.button)
                .buttonStyle(.glass)
                .frame(width: 44, height: 44)
                .tint(ShellPalette.cream)
                .accessibilityLabel(ShellStrings.text("Move A B X Y together"))
                .accessibilityIdentifier("touchLayout.together")
                .shellTarget("lay.row.\(Self.togetherRow)") { model.setTogether(!model.together) }
            }
        }
        .padding(6)
        .frame(width: selectedToolbarWidth(for: selected), height: 56)
        }

    }

    /// Where the active control is drawn beyond its kept place: under the finger on a refused spot, or on its way back.
    private func activeOffset(_ g: PadGeo) -> CGSize {
        if let drag, let refused = drag.refused {
            let kept = model.dragOffset(drag.control)
            return CGSize(width: CGFloat(refused.dx - kept.dx) * g.step + bounce.width, height: CGFloat(refused.dy - kept.dy) * g.step + bounce.height)
        }
        return bounce
    }

    /// The active control and the controls that move with it: the diamond's keys while they move together.
    private func isActive(_ c: TouchLayout.Control, _ active: TouchLayout.Control?) -> Bool {
        guard let active else { return false }
        return model.editing.mover(c) == model.editing.mover(active)
    }

    private func drawBackdrop(_ g: PadGeo, in context: inout GraphicsContext) {
        // The picture: the whole screen over which the controls float, or its own area above the controls on a split screen.
        let picture = g.region.separated ? g.region.game : g.region.game.intersection(CGRect(origin: .zero, size: screen.size))
        context.fill(Path(roundedRect: picture, cornerRadius: 10), with: .color(.white.opacity(g.region.separated ? 0.07 : 0.03)))
        if g.region.separated {
            context.fill(Path(g.region.controls), with: .color(.black.opacity(0.18)))
        }
    }

    private func drawGuides(for active: TouchLayout.Control, _ g: PadGeo, k: CGFloat, in context: inout GraphicsContext) {
        let m = model.editing.mover(active)
        // The area it may use: a calm cream tint with a dashed edge.
        if let area = model.editing.allowedArea(active) {
            let path = Path(roundedRect: area.insetBy(dx: 1, dy: 1), cornerRadius: 14)
            context.fill(path, with: .color(ShellPalette.cream.opacity(0.06)))
            context.stroke(path, with: .color(ShellPalette.cream.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5 / k, dash: [8 / k, 6 / k]))
        }
        // Its built-in place, dashed, once it has moved.
        if model.editing.isMoved(m) {
            var built = model.editing
            built.putBack(m)
            let home = built.geo
            for c in home.drawnControls where model.editing.mover(c) == m {
                for shape in Self.shapes(c, home) {
                    context.stroke(PadDrawing.outline(shape), with: .color(ShellPalette.cream.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5 / k, dash: [5 / k, 5 / k]))
                }
            }
        }
    }

    private enum Highlight { case none, chosen, refused }

    /// The keys in the editor: brighter than in the settings' small preview, with lines of the same width at every preview size. The
    /// chosen control is filled cream with dark type and a soft halo, a refused spot red, so it reads at a glance.
    private func draw(_ c: TouchLayout.Control, _ g: PadGeo, k: CGFloat, highlight: Highlight = .none, in context: inout GraphicsContext) {
        var style = PadDrawing.Style(fill: .white.opacity(0.17), line: .white.opacity(0.62), text: .white.opacity(0.9), ring: .white.opacity(0.07),
                                     lineWidth: 1.5 / k)
        var halo: Color?
        switch highlight {
        case .none: break
        case .chosen:
            style.fill = ShellPalette.cream.opacity(model.held ? 1 : 0.9); style.line = ShellPalette.cream; style.text = .black.opacity(0.85)
            style.ring = ShellPalette.cream.opacity(0.22); style.lineWidth = 2.5 / k
            halo = ShellPalette.cream.opacity(model.held ? 0.5 : 0.32)
        case .refused:
            style.fill = DeleteStyle.red.opacity(0.9); style.line = DeleteStyle.red; style.text = .white
            style.ring = DeleteStyle.red.opacity(0.25); style.lineWidth = 2.5 / k
            halo = DeleteStyle.red.opacity(0.4)
        }
        for shape in Self.shapes(c, g) {
            if let halo { context.stroke(PadDrawing.outline(shape), with: .color(halo), lineWidth: (model.held ? 12 : 9) / k) }
            PadDrawing.draw(shape, in: &context, style: style)
        }
    }

    /// The drawn shapes of one control, in the gamepad's look.
    static func shapes(_ c: TouchLayout.Control, _ g: PadGeo) -> [TouchPadPreviewGeometry.Shape] {
        switch c {
        case .face: (0..<4).map { .circle(g.faceKey[$0], g.faceR, label: ["A", "B", "X", "Y"][$0]) }
        case .a: [.circle(g.faceKey[0], g.faceR, label: "A")]
        case .b: [.circle(g.faceKey[1], g.faceR, label: "B")]
        case .x: [.circle(g.faceKey[2], g.faceR, label: "X")]
        case .y: [.circle(g.faceKey[3], g.faceR, label: "Y")]
        case .stick: [.ring(g.stick, g.stickR, knob: g.knobR)]
        case .dpad: [.dpad(g.dpad, g.dpadR)]
        case .zl, .l, .zr, .r:
            [.drop(g.drop[PadGeo.dropIndex(c)], g.dropR[PadGeo.dropIndex(c)], tipRight: c == .zr || c == .r, label: c.title)]
        case .l3: [.circle(g.click[0], g.clickR, label: "L3")]
        case .r3: [.circle(g.click[1], g.clickR, label: "R3")]
        case .minus: [.pill(g.pill[0], label: "−")]
        case .plus: [.pill(g.pill[1], label: "+")]
        }
    }

    // MARK: Touch

    private func selectionTapGesture(k: CGFloat) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in model.select(touchedControl(at: value.location, scale: k)) }
    }

    private func touchedControl(at point: CGPoint, scale k: CGFloat) -> TouchLayout.Control? {
        model.editing.control(at: CGPoint(x: point.x / k, y: point.y / k), slop: max(22 / k, 6))
    }

    static func canDrag(_ control: TouchLayout.Control, selected: TouchLayout.Control?, together: Bool) -> Bool {
        guard let selected else { return false }
        func mover(_ control: TouchLayout.Control) -> TouchLayout.Control {
            together && control.isFaceKey ? .face : control
        }
        return mover(control) == mover(selected)
    }

    private func dragGesture(k: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard exactGeometryReady else { return }
                let t = CGSize(width: value.translation.width / k, height: value.translation.height / k)
                if drag == nil {
                    guard let c = touchedControl(at: value.startLocation, scale: k),
                          Self.canDrag(c, selected: model.selected, together: model.together) else { return }
                    bounce = .zero
                    drag = DragState(control: c, start: model.dragOffset(c))
                }
                guard var d = drag else { return }
                let result = model.dragTo(d.control, from: d.start, by: t)
                d.refused = result.kept ? nil : result.offset
                drag = d
            }
            .onEnded { _ in
                guard let d = drag else { return }
                if let refused = d.refused {
                    // Back to its kept place, from under the finger.
                    let g = model.geo, kept = model.dragOffset(d.control)
                    bounce = CGSize(width: CGFloat(refused.dx - kept.dx) * g.step, height: CGFloat(refused.dy - kept.dy) * g.step)
                    drag = nil
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25)) { bounce = .zero }
                    model.dragEnded(rejected: true)
                } else {
                    drag = nil
                    model.dragEnded(rejected: false)
                }
            }
    }

    // MARK: VoiceOver and the controller

    /// One element per control over the picture: VoiceOver names it and moves it with its actions, a controller focuses it (A picks it
    /// up). They take no touches, the drag above does.
    private func accessibilityElements(_ g: PadGeo, k: CGFloat) -> some View {
        let controls = model.together ? [TouchLayout.Control.face] + g.drawnControls.filter { !$0.isFaceKey } : g.drawnControls
        return ForEach(controls, id: \.self) { c in accessibilityElement(c, g, k: k) }
    }

    private func accessibilityElement(_ c: TouchLayout.Control, _ g: PadGeo, k: CGFloat) -> some View {
        let box = g.box(of: c)?.box ?? .zero
        let value: String = ShellStrings.text(model.editing.isMoved(c) ? "Moved" : "In its place")
        let traits: AccessibilityTraits = (model.selected.map { model.editing.mover($0) == c } == true) ? [.isButton, .isSelected] : .isButton
        return Color.clear
            .frame(width: max(box.width * k, 30), height: max(box.height * k, 30))
            .position(x: box.midX * k, y: box.midY * k)
            .accessibilityElement()
            .accessibilityLabel(c.title)
            .accessibilityValue(value)
            .accessibilityAddTraits(traits)
            .accessibilityAction { model.select(c) }
            .accessibilityAction(named: ShellStrings.text("Move up")) { voiceOverMove(c, 0, -1) }
            .accessibilityAction(named: ShellStrings.text("Move down")) { voiceOverMove(c, 0, 1) }
            .accessibilityAction(named: ShellStrings.text("Move left")) { voiceOverMove(c, -1, 0) }
            .accessibilityAction(named: ShellStrings.text("Move right")) { voiceOverMove(c, 1, 0) }
            .accessibilityAction(named: ShellStrings.text("Reset this control")) { model.select(c); model.putBack() }
            .shellTarget("lay.ctl.\(c.rawValue)", radius: max(box.width, box.height) * k / 2) { model.pickUp(c) }
            .allowsHitTesting(false)
    }

    private func voiceOverMove(_ c: TouchLayout.Control, _ dx: Int, _ dy: Int) {
        model.select(c)
        let outcome = model.nudge(dx: dx, dy: dy)
        let text = outcome == .moved ? ShellStrings.text("Moved") : outcome == .atEdge ? ShellStrings.text("At the edge") : ShellStrings.text("No room there")
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Contextual controls

    /// Reset the selected control.
    private var selectedReset: some View {
        let canPutBack = exactGeometryReady && (model.selected.map { model.editing.isMoved($0) } ?? false)
        return Button { if !ignoresPress() { model.putBack() } } label: {
            Image(systemName: "arrow.counterclockwise")
        }
            .buttonStyle(.glass)
            .frame(width: 44, height: 44)
            .accessibilityLabel(ShellStrings.text("Reset this control"))
            .disabled(!canPutBack)
            .accessibilityIdentifier("touchLayout.putBack")
            .shellTarget("lay.putBack", enabled: canPutBack) { model.putBack() }
    }


}

/// The Arrangement row of the shell settings' Touch controls group: whether the controls are where they are built in, and the button
/// that opens the editor.
struct TouchArrangeRow: View {
    var arranged: Bool
    @Environment(\.shellOpenTouchLayout) private var open
    var body: some View {
        Button { open?() } label: {
            HStack {
                Label(ShellStrings.text("Touch controls"), systemImage: "hand.draw")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(ShellStrings.text(arranged ? "Your own" : "Built in"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.automatic)
        .accessibilityIdentifier("shellSettings.arrange")
        .shellTarget("shs.arrange") { open?() }
    }
}

private struct ShellOpenTouchLayoutKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    /// Opens the touch controls' layout editor. The library provides it.
    var shellOpenTouchLayout: (() -> Void)? {
        get { self[ShellOpenTouchLayoutKey.self] }
        set { self[ShellOpenTouchLayoutKey.self] = newValue }
    }
}

extension TouchLayout.Control {
    /// The control's name, for the status line and VoiceOver.
    var title: String {
        switch self {
        case .face: "A B X Y"
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .stick: ShellStrings.text("Left stick")
        case .dpad: ShellStrings.text("D-pad")
        case .zl: "ZL"
        case .l: "L"
        case .zr: "ZR"
        case .r: "R"
        case .l3: "L3"
        case .r3: "R3"
        case .minus: ShellStrings.text("Minus")
        case .plus: ShellStrings.text("Plus")
        }
    }
}

private struct TouchEditorTip: Tip {
    let id = UUID().uuidString
    var title: Text { Text(ShellStrings.text("Edit controls here. Save when finished.")) }
}

private struct ShellDismissTouchEditorKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var shellDismissTouchEditor: (() -> Void)? {
        get { self[ShellDismissTouchEditorKey.self] }
        set { self[ShellDismissTouchEditorKey.self] = newValue }
    }
}
