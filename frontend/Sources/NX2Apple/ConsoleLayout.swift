import SwiftUI
import NXCore
import NXLauncher

/// Console mode's building blocks for a page read from across a room (LNPANDY/NX2Apple#1458, the console pass): the two columns of
/// a page (the game's artwork on the left, the content on the right), the controller hint bar under them, the flat segmented
/// control, the grouped list and its rows, the value stepper, the stats card and the notice. Everything takes DS.Console sizes and
/// the DS colours. The focus is the cream ring (DS.Console.Control.focusRing) and a slightly raised surface. Nothing changes size.

// MARK: Focus

/// A console focus target: the pad target, its own 4 pt cream ring when focused, and whether it is focused for the surface under it.
struct ConsoleFocusModifier: ViewModifier {
    let id: String
    let scope: String
    let radius: CGFloat
    var enabled = true
    var activate: (() -> Void)?
    var adjust: ((Int) -> Void)?
    var vertical: ((Int) -> Bool)?
    @EnvironmentObject private var pad: PadFocus

    func body(content: Content) -> some View {
        let on = enabled && pad.visible && pad.focused == id
        return content
            .overlay {
                if on {   // never a stroke of width 0: Core Graphics draws that as a hairline
                    RoundedRectangle(cornerRadius: radius).strokeBorder(DS.Color.accent, lineWidth: DS.Console.Control.focusRing).allowsHitTesting(false)
                }
            }
            .padTarget(id, scope: scope, radius: radius, enabled: enabled, activate: activate, adjust: adjust, vertical: vertical)
            .environment(\.padRingStyle, .none)
            .id(id)
    }
}

extension View {
    func consoleFocus(_ id: String, scope: String, radius: CGFloat = DS.Console.Radius.row, enabled: Bool = true,
                      activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil, vertical: ((Int) -> Bool)? = nil) -> some View {
        modifier(ConsoleFocusModifier(id: id, scope: scope, radius: radius, enabled: enabled, activate: activate, adjust: adjust, vertical: vertical))
    }
}

/// Whether a pad target is the focused one, for the raised surface under a focused row.
struct ConsoleFocused<Content: View>: View {
    let id: String
    @ViewBuilder let content: (Bool) -> Content
    @EnvironmentObject private var pad: PadFocus
    var body: some View { content(pad.visible && pad.focused == id) }
}

// MARK: Hint bar

/// One button and what it does in the hint bar: the controller's glyph and a label. A click does it too.
struct ConsoleHintItem: Identifiable {
    let glyph: ConsoleGlyphs.Glyph
    let label: String
    let action: () -> Void
    var id: String { label }
}

/// The bar at the bottom of a page: which buttons do what here, instead of big Back and Stop buttons. Not a focus target: the
/// controller presses the buttons it names.
struct ConsoleHintBar: View {
    let items: [ConsoleHintItem]
    var trailing: [ConsoleHintItem] = []
    /// The items centred under the content column instead of at its ends (the starting screen's Back, #1458).
    var centered = false
    var body: some View {
        HStack(spacing: DS.Console.Space.xl) {
            if centered { Spacer(minLength: DS.Console.Space.m) }
            ForEach(items) { item in hint(item) }
            Spacer(minLength: DS.Console.Space.m)
            ForEach(trailing) { item in hint(item) }
        }
        .frame(height: DS.Console.Control.hintBar)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.separator).frame(height: 1) }
    }

    private func hint(_ item: ConsoleHintItem) -> some View {
        Button(action: item.action) {
            HStack(spacing: DS.Console.Space.xs) {
                ConsoleGlyphView(glyph: item.glyph, size: DS.Console.Control.glyph).foregroundStyle(DS.Color.symbolDefault)
                Text(item.label).font(DS.Console.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ConsoleGlyphs {
    /// Left and right on the D-pad or the arrow keys, for "Adjust".
    static var adjustGlyph: Glyph { .keySymbol("arrow.left.and.right") }
}

// MARK: Two columns

/// A pill displayed in console mode's art column and supported-games list.
struct ConsoleContextTag: Equatable {
    enum Width: Equatable { case auto, platform, engine }
    var title: String
    var emphasized: Bool = false
    var width: Width = .auto
}

/// A console-scaled quiet tag matching `DSTag` geometry for across-the-room readability.
struct ConsoleTag: View {
    static func platformWidth(compact: Bool) -> CGFloat { compact ? 80 : 90 }
    static func engineWidth(compact: Bool) -> CGFloat { compact ? 130 : 152 }

    let title: String
    var emphasized: Bool = false
    var compact: Bool = false
    var width: CGFloat? = nil

    var body: some View {
        Text(title)
            .font(compact ? DS.Font.callout.weight(.semibold) : DS.Font.bodyStrong)
            .foregroundStyle(emphasized ? DS.Color.textPrimary : DS.Color.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: width == nil, vertical: true)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, 3)
            .frame(width: width)
            .background(DS.Color.surfaceRaised, in: DSPill())
            .overlay(DSPill().strokeBorder(emphasized ? DS.Color.textTertiary : DS.Color.separator))
    }
}

/// What the left column of a page shows: the game's artwork, its title, optional pills and one secondary line.
struct ConsolePageContext {
    var image: NSImage?
    var focus: UnitPoint = .center
    var title: String
    var subtitle: String = ""
    var tags: [ConsoleContextTag] = []
    /// A progress bar under the subtitle (the build page's running build), 0 to 1.
    var progress: Double?
}

/// The artwork column: the art sharp, dimmed with the page gradient into the background on its right and at its bottom, the title in
/// the console's large title and one secondary line at the bottom left. No blur, no page name in giant type.
struct ConsoleArtColumn: View {
    let context: ConsolePageContext
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = context.image { ArtworkFill(image: image, focus: context.focus) }
                    else { LinearGradient(colors: ConsolePlaceholder.colors(for: context.title), startPoint: .topLeading, endPoint: .bottomTrailing) }
                }
                .frame(width: g.size.width, height: g.size.height).clipped()
                // dimmed into the page: towards the content on the right and under the title at the bottom
                LinearGradient(stops: [.init(color: DS.Color.background.opacity(0), location: 0.55), .init(color: DS.Color.background, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: DS.Color.background.opacity(0.15), location: 0), .init(color: DS.Color.background.opacity(0.35), location: 0.45),
                                       .init(color: DS.Color.background.opacity(0.92), location: 1)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: DS.Console.Space.s) {
                    Text(context.title).font(DS.Console.Font.largeTitle).tracking(DS.Console.Font.largeTitleTracking)
                        .foregroundStyle(DS.Color.textPrimary).lineLimit(3).minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    if !context.tags.isEmpty {
                        DSFlowRow(spacing: DS.Space.xs) {
                            ForEach(Array(context.tags.enumerated()), id: \.offset) { _, tag in
                                ConsoleTag(
                                    title: tag.title,
                                    emphasized: tag.emphasized,
                                    compact: false,
                                    width: {
                                        switch tag.width {
                                        case .auto: return nil
                                        case .platform: return ConsoleTag.platformWidth(compact: false)
                                        case .engine: return ConsoleTag.engineWidth(compact: false)
                                        }
                                    }()
                                )
                            }
                        }
                    }
                    if !context.subtitle.isEmpty {
                        Text(context.subtitle).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(2)
                    }
                    if let progress = context.progress { ConsoleProgressBar(fraction: progress).frame(maxWidth: 420).padding(.top, DS.Console.Space.xs) }
                }
                .padding(.leading, DS.Console.Space.gutter).padding(.trailing, DS.Console.Space.xl).padding(.bottom, DS.Console.Space.xl)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A page over the whole screen: the context column on the left (45 %, DS.Console.Scale.artColumn), the content on the right and
/// the hint bar at the bottom of the content. Narrow windows drop the artwork and keep the title above the content.
struct ConsolePageLayout<Leading: View, Content: View>: View {
    let compact: Bool
    let context: ConsolePageContext
    let hints: [ConsoleHintItem]
    var trailingHints: [ConsoleHintItem] = []
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { g in
            let artWidth = compact ? 0 : (g.size.width * DS.Console.Scale.artColumn).rounded()
            HStack(spacing: 0) {
                if !compact { leading().frame(width: artWidth, height: g.size.height).clipped() }
                VStack(alignment: .leading, spacing: 0) {
                    if compact {
                        Text(context.title).font(DS.Console.Font.title).foregroundStyle(DS.Color.textPrimary).lineLimit(2)
                            .padding(.horizontal, DS.Console.Space.l).padding(.top, DS.Console.Space.l).accessibilityAddTraits(.isHeader)
                    }
                    content()
                        .frame(maxWidth: DS.Console.Control.contentWidth, maxHeight: .infinity, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    ConsoleHintBar(items: hints, trailing: trailingHints)
                        .padding(.horizontal, compact ? DS.Console.Space.l : DS.Console.Space.xl)
                        .padding(.trailing, compact ? 0 : DS.Console.Space.xl)
                        .padding(.bottom, DS.Console.Space.s)
                }
                .frame(width: g.size.width - artWidth, height: g.size.height)
            }
        }
        .background(DS.Color.background)
    }
}

extension ConsolePageLayout where Leading == ConsoleArtColumn {
    init(compact: Bool, context: ConsolePageContext, hints: [ConsoleHintItem], trailingHints: [ConsoleHintItem] = [], @ViewBuilder content: @escaping () -> Content) {
        self.init(compact: compact, context: context, hints: hints, trailingHints: trailingHints, leading: { ConsoleArtColumn(context: context) }, content: content)
    }
}

/// A thin progress line: the filled part in the accent, the rest on the separator.
struct ConsoleProgressBar: View {
    let fraction: Double
    var height: CGFloat = DS.Console.Control.valueBar
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.separator)
                Capsule().fill(DS.Color.accent).frame(width: g.size.width * ConsoleValueBar.clamped(fraction))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: DS.Motion.standard), value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: Segmented control

/// One flat segmented control: equal segments, the chosen one filled inside the control, the shoulder buttons' glyphs at both ends,
/// centred on the control. A click or A on a segment picks it.
struct ConsoleSegmentedControl: View {
    let segments: [(id: String, title: String)]
    let selected: Int
    var previousGlyph: ConsoleGlyphs.Glyph?
    var nextGlyph: ConsoleGlyphs.Glyph?
    let scope: String
    let idPrefix: String
    let pick: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DS.Console.Space.s) {
            if let previousGlyph { ConsoleGlyphView(glyph: previousGlyph, size: DS.Console.Control.glyph).foregroundStyle(DS.Color.symbolDefault) }
            HStack(spacing: DS.Console.Space.xxs) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let on = index == selected
                    Button { pick(index) } label: {
                        Text(segment.title).font(on ? DS.Console.Font.bodyStrong : DS.Console.Font.body).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(on ? DS.Color.accentOn : DS.Color.textSecondary)
                            .frame(maxWidth: .infinity).frame(height: DS.Console.Control.segment - 2 * DS.Console.Space.xxs)
                            .background(on ? DS.Color.accent : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                    .consoleFocus(idPrefix + segment.id, scope: scope, radius: (DS.Console.Control.segment - 2 * DS.Console.Space.xxs) / 2) { pick(index) }
                }
            }
            .padding(DS.Console.Space.xxs)
            .frame(height: DS.Console.Control.segment)
            .background(DS.Color.surface, in: Capsule())
            .overlay(RoundedRectangle(cornerRadius: DS.Console.Control.segment / 2).strokeBorder(DS.Color.separator))
            if let nextGlyph { ConsoleGlyphView(glyph: nextGlyph, size: DS.Console.Control.glyph).foregroundStyle(DS.Color.symbolDefault) }
        }
    }
}

extension DS.Console.Space {
    static let xxs: CGFloat = DS.Space.xxs
}

// MARK: Grouped list

/// A section of rows: a sentence-case header in the console headline, the rows on one surface with hairlines between them.
struct ConsoleGroupedList<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Console.Space.s) {
            if let title, !title.isEmpty {
                Text(title).font(DS.Console.Font.headline).foregroundStyle(DS.Color.textPrimary)
                    .padding(.leading, DS.Console.Space.xxs).accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content() }
                .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Console.Radius.row))
                .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.row).strokeBorder(DS.Color.separator))
            if let footer, !footer.isEmpty {
                Text(footer).font(DS.Console.Font.footnote).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, DS.Console.Space.xxs)
            }
        }
    }
}

/// The hairline between two rows of a grouped list.
struct ConsoleRowDivider: View {
    var body: some View { Rectangle().fill(DS.Color.separator).frame(height: 1).padding(.leading, DS.Console.Space.l) }
}

/// What a row shows at its right.
enum ConsoleRowAccessory {
    case chevron
    case expanded(Bool)
    case value(String)
    case none
}

/// A row of a grouped list that opens something: its title, one line under it, what it holds now, a chevron. One height for every
/// row (DS.Console.Control.rowHeight). Focused: the ring and the raised surface.
struct ConsoleListRow: View {
    let id: String
    let scope: String
    let title: String
    var subtitle = ""
    var accessory: ConsoleRowAccessory = .chevron
    var enabled = true
    let action: () -> Void

    var body: some View {
        ConsoleFocused(id: id) { focused in
            Button(action: action) {
                HStack(spacing: DS.Console.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(title).font(DS.Console.Font.body).foregroundStyle(enabled ? DS.Color.textPrimary : DS.Color.textTertiary).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: DS.Console.Space.s)
                    switch accessory {
                    case .chevron: chevron("chevron.right")
                    case .expanded(let open): chevron(open ? "chevron.down" : "chevron.right")
                    case .value(let text):
                        Text(text).font(DS.Console.Font.body).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                        chevron("chevron.right")
                    case .none: EmptyView()
                    }
                }
                .padding(.horizontal, DS.Console.Space.l)
                .frame(maxWidth: .infinity, minHeight: DS.Console.Control.rowHeight, alignment: .leading)
                .background(focused ? DS.Color.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: DS.Console.Radius.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .consoleFocus(id, scope: scope, enabled: enabled, activate: action)
        .accessibilityLabel(title).accessibilityHint(subtitle)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.symbolDefault).accessibilityHidden(true)
    }
}

/// A row that only says something (a cheat that is always on, a fact): the title, the value, no focus.
struct ConsoleInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: DS.Console.Space.m) {
            Text(title).font(DS.Console.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            Spacer(minLength: DS.Console.Space.s)
            Text(value).font(DS.Console.Font.body).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, DS.Console.Space.l)
        .frame(maxWidth: .infinity, minHeight: DS.Console.Control.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A switch on a row of a grouped list: the title (and one line), the switch at the right. A, left or right flips it. A row that
/// cannot be switched is dimmed and takes no focus.
struct ConsoleToggleListRow: View {
    let id: String
    let scope: String
    let title: String
    var subtitle = ""
    let isOn: Bool
    var enabled = true
    let flip: () -> Void

    var body: some View {
        ConsoleFocused(id: id) { focused in
            HStack(spacing: DS.Console.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title).font(DS.Console.Font.body).foregroundStyle(enabled ? DS.Color.textPrimary : DS.Color.textTertiary).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Console.Space.s)
                ConsoleSwitch(isOn: isOn, compact: false).opacity(enabled ? 1 : 0.45)
            }
            .padding(.horizontal, DS.Console.Space.l)
            .frame(maxWidth: .infinity, minHeight: DS.Console.Control.rowHeight, alignment: .leading)
            .background(focused ? DS.Color.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: DS.Console.Radius.row))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { flip() } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityHint(subtitle).accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(.isButton)
        .consoleFocus(id, scope: scope, enabled: enabled, activate: flip, adjust: { _ in flip() })
    }
}

// MARK: Value stepper

/// The fill of the thin bar under a continuous value: where the value sits between the setting's lowest and highest value, so a
/// full bar is the highest value and an empty one the lowest (ConsoleValueStepperTests).
enum ConsoleValueBar {
    static func clamped(_ fraction: Double) -> Double { fraction.isFinite ? min(max(fraction, 0), 1) : 0 }
    static func fillFraction(value: Double, lo: Double, hi: Double) -> Double {
        guard hi > lo, value.isFinite else { return 0 }
        return clamped((value - lo) / (hi - lo))
    }
    /// A range is continuous when it has more steps than a stepper reads at a glance: then it shows the bar.
    static let continuousSteps = 10
    static func isContinuous(lo: Double, hi: Double, step: Double) -> Bool {
        guard hi > lo, step > 0, step.isFinite else { return false }
        return ((hi - lo) / step).rounded() > Double(continuousSteps)
    }
}

/// "‹ 100 % ›": the value between two chevrons, which dim at the ends. Left and right change it on the row, a click on a chevron too.
/// A setting with one value shows the value alone.
struct ConsoleValueStepper: View {
    let label: String
    let canDecrease: Bool
    let canIncrease: Bool
    /// Nil: no chevrons, the value cannot change (a game with one language).
    var fixed = false
    /// The bar's fill for a continuous value.
    var fill: Double?
    let step: (Int) -> Void

    var body: some View {
        VStack(spacing: DS.Console.Space.xs) {
            HStack(spacing: DS.Console.Space.xs) {
                if !fixed { chevron("chevron.left", enabled: canDecrease) { step(-1) } }
                Text(label).font(DS.Console.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: fixed ? .trailing : .center)
                if !fixed { chevron("chevron.right", enabled: canIncrease) { step(1) } }
            }
            if let fill {
                ConsoleProgressBar(fraction: fill).padding(.horizontal, DS.Console.Space.xl)
            }
        }
        .frame(width: DS.Console.Control.stepper)
    }

    private func chevron(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .bold))
            .foregroundStyle(enabled ? DS.Color.textPrimary : DS.Color.textTertiary)
            .frame(width: DS.Console.Space.xl, height: DS.Console.Space.xl).contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .accessibilityHidden(true)
    }
}

// MARK: Stats card

/// Read-only facts side by side: equal columns split by hairlines, the label in the footnote, the value in the headline.
struct ConsoleStatsCard: View {
    let items: [(label: String, value: String)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Rectangle().fill(DS.Color.separator).frame(width: 1).padding(.vertical, DS.Console.Space.m) }
                VStack(alignment: .leading, spacing: DS.Console.Space.xs) {
                    Text(item.label).font(DS.Console.Font.footnote).foregroundStyle(DS.Color.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                    Text(item.value).font(DS.Console.Font.headline).foregroundStyle(DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
                }
                .padding(.horizontal, DS.Console.Space.l).padding(.vertical, DS.Console.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Console.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.card).strokeBorder(DS.Color.separator))
    }
}

// MARK: Notice

/// A notice at the console's size, with the launcher's fixed symbol per tone (LauncherNoticeItem.Tone): the symbol in its status
/// colour, the title, one secondary line and at most one action.
struct ConsoleNoticeCard: View {
    let tone: LauncherNoticeItem.Tone
    let title: String
    var detail = ""
    var action: (title: String, id: String, scope: String, perform: () -> Void)?

    private var color: Color {
        switch tone {
        case .error: return DS.Color.statusError
        case .warning: return DS.Color.statusWarning
        case .info: return DS.Color.statusInfo
        case .success: return DS.Color.statusSuccess
        }
    }

    var body: some View {
        HStack(spacing: DS.Console.Space.m) {
            Image(systemName: tone.symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Console.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action: action.perform) {
                    Text(action.title).font(DS.Console.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                        .padding(.horizontal, DS.Console.Space.l).frame(height: DS.Console.Control.segment)
                        .background(DS.Color.surfaceRaised, in: Capsule()).overlay(RoundedRectangle(cornerRadius: DS.Console.Control.segment / 2).strokeBorder(DS.Color.separator))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).fixedSize()
                .consoleFocus(action.id, scope: action.scope, radius: DS.Console.Control.segment / 2, activate: action.perform)
            }
        }
        .padding(DS.Console.Space.l)
        .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Console.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.card).strokeBorder(DS.Color.separator))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Buttons

/// A flat button on a card (Identify, Assign player): the raised surface with a hairline. `destructive` is a text button in the error colour.
struct ConsoleFlatButton: View {
    let id: String
    let scope: String
    let title: String
    var symbol: String?
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Console.Space.xs) {
                if let symbol { Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(destructive ? DS.Color.statusError : DS.Color.symbolDefault) }
                Text(title).font(DS.Console.Font.bodyStrong).foregroundStyle(destructive ? DS.Color.statusError : DS.Color.textPrimary).lineLimit(1)
            }
            .padding(.horizontal, destructive ? DS.Console.Space.s : DS.Console.Space.l).frame(height: DS.Console.Control.segment)
            .background { if !destructive { Capsule().fill(DS.Color.surfaceRaised) } }
            .overlay { if !destructive { RoundedRectangle(cornerRadius: DS.Console.Control.segment / 2).strokeBorder(DS.Color.separator) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel(title)
        .consoleFocus(id, scope: scope, radius: DS.Console.Control.segment / 2, activate: action)
    }
}
