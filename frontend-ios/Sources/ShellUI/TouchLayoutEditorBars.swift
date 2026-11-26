import SwiftUI

extension TouchLayoutEditorView {
    private var activeOrientationTitle: String {
        if model.activeOrientation == .portrait {
            return ShellStrings.text("Portrait")
        }
        return ShellStrings.text(liveHingeStatus == .closed ? "Landscape (Duo outer screen)" : "Landscape")
    }

    private func orientationShortTitle(_ orientation: ShellSettingsStore.TouchOrientation) -> String {
        ShellStrings.text(orientation == .landscape ? "Landscape" : "Portrait")
    }

    // MARK: - Top Persistent Liquid Glass Bar

    var editorTopBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                editorCancelButton
                    .frame(width: 44, height: 44)
                Spacer(minLength: 4)
                orientationSegmentBar
                Spacer(minLength: 4)
                editorDoneButton
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var orientationSegmentBar: some View {
        HStack(spacing: 4) {
            ForEach(ShellSettingsStore.TouchOrientation.allCases, id: \.self) { orientation in
                orientationSegmentButton(orientation)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("touchLayout.orientation")
    }

    private func orientationSegmentButton(_ orientation: ShellSettingsStore.TouchOrientation) -> some View {
        let selected = model.activeOrientation == orientation
        let customized = model.isCustomized(for: orientation)
        let isPortrait = orientation == .portrait
        let lockedHalfOpen = (model.actualScreen?.partiallyOpen ?? false) || liveHingeStatus == .partiallyOpen
        let traits: AccessibilityTraits = selected ? [.isButton, .isSelected] : .isButton
        let dotColor = selected ? Color(red: 0.10, green: 0.52, blue: 0.24) : ShellPalette.ready
        let accessValue = customized ? ShellStrings.text("Custom") : ShellStrings.text("Built in")

        return Button {
            if !ignoresPress(), !lockedHalfOpen {
                hintVisible = false
                model.selectOrientation(portrait: isPortrait)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isPortrait ? "rectangle.portrait" : "rectangle")
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: orientationShortTitle(orientation))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if customized {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? .black : .white.opacity(0.86))
            .background {
                if selected {
                    Capsule().fill(ShellPalette.cream)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(lockedHalfOpen && !selected)
        .accessibilityIdentifier("touchLayout.orientation.\(orientation.rawValue)")
        .accessibilityLabel(orientationShortTitle(orientation))
        .accessibilityValue(accessValue)
        .accessibilityAddTraits(traits)
        .shellTarget("lay.pose.\(orientation.rawValue)", enabled: !lockedHalfOpen || selected) {
            hintVisible = false
            model.selectOrientation(portrait: isPortrait)
        }
    }

    // MARK: - Cross-Orientation Preview Banner

    @ViewBuilder
    var crossOrientationBanner: some View {
        if model.isCrossOrientationPreview {
            HStack(spacing: 10) {
                Image(systemName: model.activeOrientation == .landscape ? "iphone.landscape" : "iphone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ShellPalette.cream)
                Text(ShellStrings.text(model.activeOrientation == .landscape
                    ? "Previewing landscape (screen locked)"
                    : "Previewing portrait (screen locked)"))
                    .shellText(12, .medium, relativeTo: .caption)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                #if os(iOS)
                if model.canRotatePhysicalOrientation, rotateEditor != nil {
                    Button {
                        if !ignoresPress() {
                            rotateEditor?(model.activeOrientation == .portrait)
                        }
                    } label: {
                        Text(ShellStrings.text("Rotate to expand"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(ShellPalette.cream, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("touchLayout.rotateToExpand")
                    .shellTarget("lay.rotate") {
                        rotateEditor?(model.activeOrientation == .portrait)
                    }
                }
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("touchLayout.crossBanner")
        }
    }

    // MARK: - Bottom Independent Controls Dock

    @ViewBuilder
    func editorBottomDock(physicalPortrait: Bool) -> some View {
        Group {
            if physicalPortrait {
                portraitBottomDock
            } else {
                landscapeCompactDock
            }
        }
        .confirmationDialog(
            ShellStrings.text("Reset this orientation?"),
            isPresented: Binding(get: { model.confirmingReset }, set: { if !$0 { model.cancelReset() } }),
            titleVisibility: .visible
        ) {
            Button(resetButtonTitle, role: .destructive) {
                if !ignoresPress() {
                    model.reset()
                }
            }
            .accessibilityIdentifier("touchLayout.resetAll.confirm")
            Button(ShellStrings.text("Cancel"), role: .cancel) {
                model.cancelReset()
            }
            .accessibilityIdentifier("touchLayout.resetAll.cancel")
        } message: {
            Text(ShellStrings.text("Restore all button positions, size, left stick placement, and layout mode for \(activeOrientationTitle) to built-in defaults. The other orientation stays untouched."))
        }
    }

    private var resetButtonTitle: String {
        ShellStrings.text(model.activeOrientation == .landscape ? "Reset Landscape" : "Reset Portrait")
    }

    private var portraitBottomDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ShellStrings.text(model.activeOrientation == .landscape ? "Editing: Landscape" : "Editing: Portrait"))
                        .shellText(13, .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(ShellStrings.text("Saved separately"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ShellPalette.cream.opacity(0.76))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                resetOrientationButton(compact: false)
                    .fixedSize(horizontal: true, vertical: false)
            }

            dockControlRow(label: ShellStrings.text("Layout")) {
                modeSegmentedPills
            }
            dockControlRow(label: ShellStrings.text("Size")) {
                sizeSegmentedPills
            }
            dockControlRow(label: ShellStrings.text("Left stick")) {
                stickSegmentedPills
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ShellPalette.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("touchLayout.bottomDock")
    }

    private var landscapeCompactDock: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    modeSegmentedPills
                    dividerHairline
                    sizeSegmentedPills
                    dividerHairline
                    stickSegmentedPills
                    dividerHairline
                    resetOrientationButton(compact: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(ShellPalette.surface.opacity(0.84), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("touchLayout.bottomDock")
    }

    private var dividerHairline: some View {
        Rectangle()
            .fill(.white.opacity(0.16))
            .frame(width: 1, height: 18)
    }

    private func dockControlRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .shellText(12, .medium, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.72))
                .frame(minWidth: 68, alignment: .leading)
                .lineLimit(1)
            Spacer(minLength: 4)
            content()
        }
    }

    private var modeSegmentedPills: some View {
        let items: [(id: String, title: String, full: Bool)] = [("2d", "2D", false), ("3d", "3D", true)]
        return HStack(spacing: 3) {
            ForEach(items, id: \.id) { item in
                let active = model.kind.full == item.full
                dockPillButton(
                    title: item.title,
                    selected: active,
                    id: "touchLayout.mode.\(item.id)",
                    target: "lay.mode.\(item.id)"
                ) {
                    model.setKind(.of(full: item.full, split: model.kind.split))
                }
            }
        }
        .padding(3)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private var sizeSegmentedPills: some View {
        let items: [(id: String, title: String)] = [
            ("small", ShellStrings.text("Small")),
            ("medium", ShellStrings.text("Medium")),
            ("large", ShellStrings.text("Large"))
        ]
        return HStack(spacing: 3) {
            ForEach(items, id: \.id) { item in
                let active = model.editing.size == item.id
                dockPillButton(
                    title: item.title,
                    selected: active,
                    id: "touchLayout.size.\(item.id)",
                    target: "lay.size.\(item.id)"
                ) {
                    model.setSize(item.id)
                }
            }
        }
        .padding(3)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private var stickSegmentedPills: some View {
        let items: [(id: String, title: String)] = [
            ("corner", ShellStrings.text("Corner")),
            ("higher", ShellStrings.text("Higher")),
            ("inward", ShellStrings.text("Inward"))
        ]
        return HStack(spacing: 3) {
            ForEach(items, id: \.id) { item in
                let active = model.editing.stick == item.id
                dockPillButton(
                    title: item.title,
                    selected: active,
                    id: "touchLayout.stick.\(item.id)",
                    target: "lay.stick.\(item.id)"
                ) {
                    model.setStick(item.id)
                }
            }
        }
        .padding(3)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func dockPillButton(title: String, selected: Bool, id: String, target: String, action: @escaping () -> Void) -> some View {
        Button {
            if !ignoresPress() {
                hintVisible = false
                action()
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .black : .white.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule().fill(ShellPalette.cream)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .shellTarget(target, action: action)
    }

    private func resetOrientationButton(compact: Bool) -> some View {
        let enabled = model.canResetCurrentOrientation && exactGeometryReady
        return Button(role: .destructive) {
            if !ignoresPress() { model.askReset() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text(compact ? ShellStrings.text("Reset") : resetButtonTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(enabled ? DeleteStyle.red : .white.opacity(0.32))
            .background((enabled ? DeleteStyle.red.opacity(0.16) : .white.opacity(0.06)), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("touchLayout.resetAll")
        .accessibilityLabel(resetButtonTitle)
        .shellTarget("lay.resetAll", enabled: enabled) {
            model.askReset()
        }
    }
}
