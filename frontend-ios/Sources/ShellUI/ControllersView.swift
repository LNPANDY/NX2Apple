import SwiftUI

/// Connected controllers with their player and battery, and the buttons the shell listens to.
public struct ControllersView: View {
    @Environment(\.shellOpenPadMapping) private var openMapping
    @Environment(\.shellOpenButtonTest) private var openTest
    @Environment(\.shellNativeBars) private var nativeBars
    /// The ID the shell's own button mapping goes by where a game's ID would.
    public static let mappingID = "global-pad"
    public var padMap: PadMap
    @Environment(\.shellFocus) private var focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public var controllers: [ControllerInfo]
    public var onBack: () -> Void
    public init(controllers: [ControllerInfo], onBack: @escaping () -> Void = {}, padMap: PadMap = PadMap()) {
        self.padMap = padMap
        self.controllers = controllers
        self.onBack = onBack
    }
    public var body: some View {
        ScrollViewReader { proxy in
            Form {
                if !nativeBars {
                    Section {
                        LabeledContent(ShellStrings.text("Controllers")) {
                            Button(action: onBack) { Image(systemName: "xmark") }
                                .accessibilityLabel(ShellStrings.text("Close controllers"))
                                .accessibilityIdentifier("controllers.close")
                                .shellTarget("ctl.close", action: onBack)
                        }
                    }
                }
                Section {
                    if controllers.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(ShellStrings.text("No controllers connected"), systemImage: "gamecontroller")
                                .font(.headline)
                            Text(ShellStrings.text("Connect a controller in Bluetooth settings. Touch controls are always available in the library."))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(controllers) { controller in
                            ControllerRow(controller: controller)
                        }
                    }
                }
                .id("ctl.top")

                Section {
                    Button { openMapping?(Self.mappingID) } label: {
                        actionLabel(ShellStrings.text("Button mapping"),
                                    note: ShellStrings.text("What each button sends in games."),
                                    symbol: "arrow.triangle.swap",
                                    value: PadMappingRows.summary(PadMappingRows.global(padMap), game: false))
                    }
                    .accessibilityIdentifier("padMapping.open")
                    .shellTarget("ctl.mapping") { openMapping?(Self.mappingID) }
                    Button { openTest?() } label: {
                        actionLabel(ShellStrings.text("Button test"),
                                    note: ShellStrings.text("See each button light up as you press it."),
                                    symbol: "checkmark.circle")
                    }
                    .accessibilityIdentifier("buttonTest.open")
                    .shellTarget("ctl.test") { openTest?() }
                } header: {
                    Text(ShellStrings.text("Buttons"))
                }

                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        hint(Image(systemName: "dpad"), ShellStrings.text("Move between controls"))
                        hint(ButtonGlyph(role: .activate), ShellStrings.text("Select"))
                        hint(ButtonGlyph(role: .back), ShellStrings.text("Back"))
                        hint(ButtonGlyph(role: .settings), ShellStrings.text("Game settings"))
                        hint(ButtonGlyph(role: .controllers), ShellStrings.text("Controllers"))
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text(ShellStrings.text("On a controller"))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(ShellPalette.background)
            .onChange(of: focus.id) { _, id in
                guard let id, id.hasPrefix("ctl.") else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    proxy.scrollTo(id == "ctl.close" ? "ctl.top" : id,
                                   anchor: id == "ctl.close" ? .top : .center)
                }
            }
        }
        .tint(ShellPalette.cream)
        .foregroundStyle(.primary).preferredColorScheme(.dark)
    }

    private func actionLabel(_ title: String, note: String, symbol: String, value: String = "") -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
            .labelStyle(SettingsRowLabelStyle())
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private func hint(_ icon: some View, _ label: String) -> some View {
        HStack(spacing: 14) {
            icon.frame(width: 22).foregroundStyle(.white.opacity(0.75))
            Text(label).shellText(14.5).foregroundStyle(.white.opacity(0.7))
        }.accessibilityElement(children: .combine)
    }
}

private struct ControllerRow: View {
    let controller: ControllerInfo
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 16) {
                        icon
                        name
                    }
                    BatteryChip(controller: controller)
                }
            } else {
                HStack(spacing: 16) {
                    icon.fixedSize()
                    name.frame(maxWidth: .infinity, alignment: .leading)
                    BatteryChip(controller: controller)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("controller.\(controller.id)")
    }
    private var icon: some View {
        Image(systemName: "gamecontroller.fill").font(.system(size: 20))
            .frame(width: 48, height: 48)
            .background(.white.opacity(0.07), in: Circle())
            .foregroundStyle(.white.opacity(0.9))
            .accessibilityHidden(true)
    }
    private var name: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.player).textCase(.uppercase).shellText(10.5, .bold, relativeTo: .caption2).tracking(1.4)
                .foregroundStyle(ShellPalette.cream.opacity(0.8))
            Text(controller.name).shellText(16, .semibold)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Mac console's battery chip: an outline battery with its fill, and the percentage. Low is amber.
struct BatteryChip: View {
    let controller: ControllerInfo
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let low = (controller.batteryPercent ?? 100) < 20 && !controller.charging
        let tint: Color = low ? ShellPalette.attention : controller.charging ? ShellPalette.ready : .white.opacity(0.75)
        HStack(spacing: 7) {
            if let percent = controller.batteryPercent {
                BatteryShape(fraction: Double(percent) / 100, charging: controller.charging).foregroundStyle(tint)
                Text("\(percent)%").monospacedDigit()
            } else {
                Text(ShellStrings.text("No battery level"))
            }
        }
        .lineLimit(typeSize.isAccessibilitySize && controller.batteryPercent == nil ? nil : 1)
        .fixedSize(horizontal: !typeSize.isAccessibilitySize || controller.batteryPercent != nil, vertical: true)
        .shellText(12.5, .semibold, relativeTo: .footnote)
        .foregroundStyle(controller.batteryPercent == nil ? .white.opacity(0.45) : tint)
        .padding(.horizontal, 10).padding(.vertical, 4).frame(minHeight: 28)
        .background(.white.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let level = controller.batteryPercent.map { "\($0)%" } ?? ShellStrings.text("No battery level")
        return controller.charging ? level + ", " + ShellStrings.text("Charging") : level
    }
}

private struct BatteryShape: View {
    let fraction: Double
    let charging: Bool
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1.2).opacity(0.7)
                RoundedRectangle(cornerRadius: 1.5).padding(2.5)
                    .frame(width: max(7, 22 * min(1, max(0, fraction))))
            }.frame(width: 22, height: 11)
                .overlay {
                    if charging {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 1)
                            .background(ShellPalette.surface, in: Capsule())
                    }
                }
            RoundedRectangle(cornerRadius: 1).frame(width: 1.5, height: 4).opacity(0.7)
        }.accessibilityHidden(true)
    }
}
