import SwiftUI

/// A destructive action that asks for a phrase to be typed before it runs (NX Play's Remove Game and
/// Free Up Space): a click-through confirmation dialog is not enough for "deletes builds and data for good".
///
/// The phrase is the game's name — something in front of the player, not a magic word to look up.
struct TypeToConfirm: ViewModifier {
    @Binding var isPresented: Bool
    let phrase: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void
    @State private var typed = ""

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            TextField(String(format: L10n.string("confirm.typePrompt", .initial()), phrase), text: $typed)
            Button(buttonTitle, role: .destructive) {
                defer { typed = "" }
                guard typed.trimmingCharacters(in: .whitespaces) == phrase else { return }
                action()
            }
            Button(L10n.string("confirm.cancel", .initial()), role: .cancel) { typed = "" }
        } message: {
            Text(message + "\n" + String(format: L10n.string("confirm.typePrompt", .initial()), phrase))
        }
    }
}

extension View {
    func typeToConfirm(isPresented: Binding<Bool>, phrase: String, title: String, message: String,
                       buttonTitle: String, action: @escaping () -> Void) -> some View {
        modifier(TypeToConfirm(isPresented: isPresented, phrase: phrase, title: title, message: message,
                               buttonTitle: buttonTitle, action: action))
    }
}

/// The Dock icon mirrors a running build: a dark tile with the share of the work done, so a build's
/// progress is visible from wherever the launcher was left.
enum DockProgress {
    /// The text the tile shows for a progress fraction; nil clears the tile. Pure, so tests run it.
    static func percentText(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Reflects the running build on the Dock tile; nil restores the plain icon.
    static func update(_ fraction: Double?) {
        let dock = NSApplication.shared.dockTile
        guard let text = percentText(fraction) else {
            dock.contentView = nil
            dock.display()
            return
        }
        let done = min(max(fraction ?? 0, 0), 1)
        let view = NSHostingView(rootView:
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.black)
                VStack(spacing: 6) {
                    Circle().trim(from: 0, to: done).stroke(Color(red: 1.0, green: 0.85, blue: 0.62),
                                                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                    Text(text).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            .preferredColorScheme(.dark)
        )
        dock.contentView = view
        dock.display()
    }
}
