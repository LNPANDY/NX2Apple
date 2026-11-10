import SwiftUI
import NXCore
import NXLauncher

/// One of a game's options in console mode, drawn as the control it is, so a controller reads it at a glance: a switch for on and
/// off, a slider for a range, segments for a short choice (a value between arrows when the segments do not fit). The whole row is
/// one focus target: left and right change the value, A flips a switch or takes the next value. A slider is picked with A first
/// (its knob shows then) and takes left and right until A or B lets it go. A mouse uses the control itself.
struct ConsoleOptionRow: View {
    let setting: LaunchSetting
    let value: String
    /// The value as the row shows it (a percentage for the render scale, the option's name for a choice).
    let label: String
    let compact: Bool
    let lang: Lang
    let scope: String
    /// Whether this slider is picked (A), and picking or letting it go.
    let editing: Bool
    let edit: (Bool) -> Void
    /// A step left (-1) or right (+1), and a value set directly (a segment clicked, the slider dragged).
    let adjust: (Int) -> Void
    let set: (String) -> Void

    private var isOn: Bool { value == setting.onValue }
    private var isRange: Bool { setting.kind == "range" }
    /// A on a slider picks it or lets it go, on anything else it takes the next value.
    private func activate() { if isRange { edit(!editing) } else { adjust(1) } }
    /// Left and right: a slider only while it is picked.
    private func step(_ by: Int) { if !isRange || editing { adjust(by) } }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack(alignment: .center, spacing: 16) {
                Text(setting.label).font(.manrope(compact ? 17 : 20, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch setting.kind {
                case "toggle": ConsoleSwitch(isOn: isOn, compact: compact).onTapGesture { adjust(1) }
                case "range": Text(label).font(.manrope(compact ? 17 : 20, .semibold)).monospacedDigit().foregroundStyle(LauncherPalette.cream)
                default: EmptyView()
                }
            }
            switch setting.kind {
            case "range": ConsoleSlider(fraction: fraction, compact: compact, editing: editing) { edit(true); set(rangeValue(at: $0)) }
            case "choice": choice
            default: EmptyView()
            }
            if !setting.note.isEmpty {
                Text(setting.note).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, compact ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .padTarget("console.option." + setting.env, scope: scope, radius: 14, activate: activate, adjust: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(setting.label).accessibilityValue(label)
        .accessibilityHint(L10n.string("console.adjustHint", lang))
        .accessibilityAdjustableAction { direction in adjust(direction == .increment ? 1 : -1) }
        .accessibilityAction { adjust(1) }
    }

    // MARK: Choice

    private var options: [(value: String, label: String)] {
        (setting.options ?? []).compactMap { o in o.first.map { ($0, o.count > 1 ? o[1] : $0) } }
    }

    /// Segments while they fit in one row (four at most), else the value between arrows with a dot per option under it.
    @ViewBuilder private var choice: some View {
        let options = options
        if options.count <= 4 {
            ViewThatFits(in: .horizontal) {
                segments(options)
                stepper(options)
            }
        } else {
            stepper(options)
        }
    }

    private func segments(_ options: [(value: String, label: String)]) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == value
                Text(option.label).font(.manrope(compact ? 14 : 16, chosen ? .bold : .medium)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: compact ? 38 : 42)
                    .foregroundStyle(chosen ? LauncherPalette.background : .white.opacity(0.8))
                    .background(chosen ? LauncherPalette.cream : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                    .onTapGesture { set(option.value) }
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stepper(_ options: [(value: String, label: String)]) -> some View {
        let at = options.firstIndex { $0.value == value }
        return VStack(spacing: 8) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold)).frame(width: 36, height: 32).contentShape(Rectangle())
                    .onTapGesture { adjust(-1) }
                Text(label).font(.manrope(compact ? 17 : 20, .semibold)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).frame(width: 36, height: 32).contentShape(Rectangle())
                    .onTapGesture { adjust(1) }
            }
            .foregroundStyle(LauncherPalette.cream)
            HStack(spacing: 6) {
                ForEach(options.indices, id: \.self) { i in
                    Capsule().fill(i == at ? LauncherPalette.cream : .white.opacity(0.18)).frame(width: i == at ? 16 : 6, height: 6)
                }
            }
        }
        .padding(.vertical, 6)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Range

    private var bounds: (lo: Double, hi: Double, step: Double)? {
        guard let lo = setting.min, let hi = setting.max, hi > lo else { return nil }
        let step = setting.step ?? 0.05
        return (lo, hi, step > 0 && step.isFinite ? step : 0.05)
    }

    private var fraction: Double {
        guard let b = bounds else { return 0 }
        let v = Double(value) ?? Double(setting.def) ?? b.lo
        return min(max((v - b.lo) / (b.hi - b.lo), 0), 1)
    }

    /// The value at a place on the slider, on the setting's own steps.
    private func rangeValue(at fraction: Double) -> String {
        guard let b = bounds else { return value }
        let raw = b.lo + min(max(fraction, 0), 1) * (b.hi - b.lo)
        let snapped = min(max(b.lo + ((raw - b.lo) / b.step).rounded() * b.step, b.lo), b.hi)
        return String(format: "%.6g", snapped)
    }
}

/// A switch drawn at the console's size: cream with the knob at the right when on.
struct ConsoleSwitch: View {
    let isOn: Bool
    let compact: Bool
    var body: some View {
        let width: CGFloat = compact ? 48 : 56, height: CGFloat = compact ? 28 : 32
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Solid colours and no shadow: no dark rim around the knob or the track in either state.
            Capsule().fill(isOn ? LauncherPalette.cream : Color(white: 0.30))
            Circle().fill(isOn ? LauncherPalette.background : Color.white).padding(3)
        }
        .frame(width: width, height: height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        .accessibilityHidden(true)
    }
}

/// A slider drawn at the console's size: the filled part cream, a round knob at the value. A click or a drag sets the place.
/// The knob shows only while the slider is picked, growing in from nothing.
struct ConsoleSlider: View {
    let fraction: Double
    let compact: Bool
    var editing = true
    let set: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let knob: CGFloat = compact ? 20 : 24
        GeometryReader { g in
            let usable = max(g.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 6)
                Capsule().fill(LauncherPalette.cream).frame(width: knob / 2 + usable * fraction, height: 6)
                Circle().fill(LauncherPalette.cream).frame(width: knob, height: knob)
                    .scaleEffect(editing ? 1 : 0.2).opacity(editing ? 1 : 0)
                    .offset(x: usable * fraction)
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.7), value: editing)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { set(Double(($0.location.x - knob / 2) / usable)) })
            .animation(.easeOut(duration: 0.12), value: fraction)
        }
        .frame(height: knob + 8)
        .accessibilityHidden(true)
    }
}
