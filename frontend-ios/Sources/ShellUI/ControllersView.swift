import SwiftUI

/// Connected controllers with their player and battery, and the buttons the shell listens to.
public struct ControllersView: View {
    static let mappingID = "global-pad"
    public var padMap: PadMap
    public var onChange: (String, String) -> Void
    public var onReset: () -> Void
    @Environment(\.shellFocus) private var focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public var controllers: [ControllerInfo]
    public var onBack: () -> Void
    public init(controllers: [ControllerInfo], onBack: @escaping () -> Void = {}, padMap: PadMap = PadMap(),
                onChange: @escaping (String, String) -> Void = { _, _ in }, onReset: @escaping () -> Void = {}) {
        self.padMap = padMap
        self.onChange = onChange
        self.onReset = onReset
        self.controllers = controllers
        self.onBack = onBack
    }
    public var body: some View {
        // Scrolls under the home indicator to the bottom edge, with room for the last row to clear it.
        GeometryReader { geometry in
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    Text(ShellStrings.text("Controllers")).shellType(ShellType.pageTitle)
                        .lineLimit(1).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button(action: onBack) { Image(systemName: "xmark") }
                        .buttonStyle(RoundIconButtonStyle(size: 44))
                        .accessibilityLabel(ShellStrings.text("Close controllers"))
                        .accessibilityIdentifier("controllers.close")
                        .shellTarget("ctl.close", radius: 22, action: onBack).id("ctl.close")
                }
                if controllers.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light))
                            .foregroundStyle(ShellPalette.cream).accessibilityHidden(true).padding(.bottom, 4)
                        Text(ShellStrings.text("No controllers connected")).shellText(19, .bold)
                        Text(ShellStrings.text("Connect a controller in Bluetooth settings. Touch controls are always available in the library."))
                            .shellText(14.5).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).shellCard(padding: 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(controllers) { controller in
                            ControllerRow(controller: controller)
                            if controller.id != controllers.last?.id {
                                Rectangle().fill(ShellPalette.hairline).frame(height: 1).padding(.leading, 64)
                            }
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 4)
                        .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ShellPalette.hairline))
                }
                mapping
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: ShellStrings.text("On a controller"))
                    hint(Image(systemName: "dpad"), ShellStrings.text("Move between controls"))
                    hint(ButtonGlyph(role: .activate), ShellStrings.text("Select"))
                    hint(ButtonGlyph(role: .back), ShellStrings.text("Back"))
                    hint(ButtonGlyph(role: .settings), ShellStrings.text("Game settings"))
                    hint(ButtonGlyph(role: .controllers), ShellStrings.text("Controllers"))
                }.padding(.horizontal, 4)
            }.padding(24).padding(.bottom, geometry.safeAreaInsets.bottom).frame(maxWidth: 640)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: focus.id) { _, id in
            guard let id, id.hasPrefix("ctl."), !id.hasPrefix("ctl.pick.") else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: id == "ctl.close" ? .top : .center)
            }
        }
        }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
    }
    private var mapping: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: ShellStrings.text("Button mapping"))
            let swap = SettingRow(id: "swapAB", label: ShellStrings.text("Swap A and B"),
                                  note: ShellStrings.text("Only affects physical controllers in games, not shell menus. Each game can override these settings."),
                                  kind: .toggle(on: "1", off: "0"), value: padMap.swapAB ? "1" : "0")
            SettingControl(gameID: Self.mappingID, row: swap, targetPrefix: "ctl.row.") { onChange("swapAB", $0) }
                .accessibilityIdentifier("ctl.swapAB").id("ctl.row.swapAB")
            ForEach(PadMap.buttons, id: \.self) { button in
                let row = SettingRow(id: button, label: PadMap.label(button), kind: .choice(PadMap.options), value: padMap.output(for: button))
                SettingControl(gameID: Self.mappingID, row: row, targetPrefix: "ctl.row.") { onChange(button, $0) }
                    .accessibilityIdentifier("ctl.\(button)").id("ctl.row.\(button)")
            }
            Button(action: onReset) { Text(ShellStrings.text("Reset to default")) }
                .buttonStyle(ChipButtonStyle()).accessibilityIdentifier("ctl.reset")
                .shellTarget("ctl.reset", action: onReset).id("ctl.reset")
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
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            Image(systemName: "gamecontroller.fill").font(.system(size: 20))
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.07), in: Circle())
                .foregroundStyle(.white.opacity(0.9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.player.uppercased()).shellText(10.5, .bold, relativeTo: .caption2).tracking(1.4)
                    .foregroundStyle(ShellPalette.cream.opacity(0.8))
                Text(controller.name).shellText(16, .semibold).fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            BatteryChip(controller: controller)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(.vertical, typeSize.isAccessibilitySize ? 12 : 0)
        .accessibilityElement(children: .combine)
    }
}

/// The Mac console's battery chip: an outline battery with its fill, and the percentage. Low is amber.
struct BatteryChip: View {
    let controller: ControllerInfo
    var body: some View {
        let low = (controller.batteryPercent ?? 100) < 20 && !controller.charging
        let tint: Color = low ? ShellPalette.attention : controller.charging ? ShellPalette.ready : .white.opacity(0.75)
        HStack(spacing: 7) {
            if let percent = controller.batteryPercent {
                BatteryShape(fraction: Double(percent) / 100).foregroundStyle(tint)
                Text("\(percent)%").monospacedDigit()
                if controller.charging {
                    Image(systemName: "bolt.fill").font(.system(size: 10)).accessibilityLabel(ShellStrings.text("Charging"))
                }
            } else {
                Text(ShellStrings.text("No battery level"))
            }
        }
        .lineLimit(1).fixedSize()
        .shellText(12.5, .semibold, relativeTo: .footnote)
        .foregroundStyle(controller.batteryPercent == nil ? .white.opacity(0.45) : tint)
        .padding(.horizontal, 10).frame(minHeight: 28)
        .background(.white.opacity(0.06), in: Capsule())
    }
}

private struct BatteryShape: View {
    let fraction: Double
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1.2).opacity(0.7)
                RoundedRectangle(cornerRadius: 1.5).padding(2.5)
                    .frame(width: max(7, 22 * min(1, max(0, fraction))))
            }.frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1).frame(width: 1.5, height: 4).opacity(0.7)
        }.accessibilityHidden(true)
    }
}
