import SwiftUI
import GameController
import NXCore
import NXModel
import NXLauncher

/// The live stick positions of the first connected controller, for the preview (#1025). Read-only: it never feeds a game.
@MainActor final class StickInputMonitor: ObservableObject {
    @Published private(set) var left = CGPoint.zero
    @Published private(set) var right = CGPoint.zero
    @Published private(set) var controllerName: String?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }), let pad = controller.extendedGamepad else {
            controllerName = nil; left = .zero; right = .zero
            return
        }
        controllerName = controller.vendorName ?? controller.productCategory
        left = CGPoint(x: Double(pad.leftThumbstick.xAxis.value), y: Double(pad.leftThumbstick.yAxis.value))
        right = CGPoint(x: Double(pad.rightThumbstick.xAxis.value), y: Double(pad.rightThumbstick.yAxis.value))
    }
}

/// A stick drawn at 78 x 78: its range, the deadzone as a dashed circle, the input as an outline and the filtered output as the cream marker.
struct StickVisualizer: View {
    static let size: CGFloat = 78
    let input: CGPoint
    let percent: Int
    var body: some View {
        let out = StickDeadzoneSettings.output(x: Double(input.x), y: Double(input.y), percent: percent)
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2 - 6
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(LauncherPalette.ink(0.28)), lineWidth: 1.5)
            if percent > 0 {
                let d = r * CGFloat(percent) / 100
                context.stroke(Path(ellipseIn: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)), with: .color(LauncherPalette.ink(0.35)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + CGFloat(x) * r, y: c.y - CGFloat(y) * r) }
            let i = point(Double(input.x), Double(input.y)), o = point(out.x, out.y)
            context.stroke(Path(ellipseIn: CGRect(x: i.x - 6, y: i.y - 6, width: 12, height: 12)), with: .color(LauncherPalette.ink(0.85)), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(LauncherPalette.cream))
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityElement(children: .ignore)
    }
}

/// Settings > Controls, below the controller actions: "Use custom deadzones", a left and a right stick (0 to 50 percent), a live preview of the
/// input and the filtered output, and Reset. Off keeps what the engine does without it.
struct StickDeadzoneCard: View {
    @ObservedObject var store: StickDeadzoneStore
    @StateObject private var monitor = StickInputMonitor()
    @EnvironmentObject var loc: Localizer

    private var settings: StickDeadzoneSettings { store.settings }

    var body: some View {
        CardGroup(loc.t("sticks.group")) {
            // The controller the preview follows, named above it: the first connected one.
            CardRow(monitor.controllerName ?? loc.t("sticks.noController"), detail: monitor.controllerName == nil ? "" : loc.t("sticks.previewOf"),
                    dot: monitor.controllerName == nil ? LauncherPalette.unbuilt : LauncherPalette.ready) {}
            CardDivider()
            CardRow(loc.t("sticks.custom"), detail: loc.t(settings.custom ? "sticks.customOn" : "sticks.customOff")) {
                Toggle(loc.t("sticks.custom"), isOn: Binding(get: { settings.custom }, set: { store.setCustom($0) }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle())
            }
            CardDivider()
            stickRow(loc.t("sticks.left"), percent: settings.left, input: monitor.left, set: store.setLeft)
            CardDivider()
            stickRow(loc.t("sticks.right"), percent: settings.right, input: monitor.right, set: store.setRight)
            CardDivider()
            HStack(spacing: 18) {
                legend(filled: false, loc.t("sticks.input"))
                legend(filled: true, loc.t("sticks.output"))
                Spacer(minLength: 12)
                Button(loc.t("savesloc.reset")) { store.reset() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(settings.isDefault)
                    .accessibilityLabel(loc.t("sticks.resetAll"))
                    .padTarget("sticks.reset", scope: "main") { store.reset() }
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func stickRow(_ title: String, percent: Int, input: CGPoint, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.manrope(14)).frame(width: 90, alignment: .leading)
            LauncherSlider(value: Double(percent), range: 0...50, step: 1) { set(Int($0.rounded())) }
                .accessibilityLabel(title)
                .accessibilityValue("\(percent)%")
                .disabled(!settings.custom)
                .opacity(settings.custom ? 1 : 0.45)
            Text("\(percent)%").font(.manrope(13, .semibold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            StickVisualizer(input: input, percent: settings.custom ? percent : 0)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    private func legend(filled: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(filled ? LauncherPalette.cream : .clear).overlay(Circle().strokeBorder(filled ? .clear : LauncherPalette.ink(0.9), lineWidth: 1.5))
                .frame(width: 10, height: 10)
            Text(text).font(.manrope(12.5)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
