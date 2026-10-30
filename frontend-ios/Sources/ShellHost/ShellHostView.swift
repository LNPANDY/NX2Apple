import SwiftUI
import ShellUI

/// `LibraryView` on a `ShellHostModel`: the real shell screen, plus the read-only log sheet and the notice alert. The
/// launch arguments of the demo (initial selection and so on) are not part of it.
public struct ShellHostView: View {
    @Bindable private var model: ShellHostModel
    private let initialSelection: String?

    public init(model: ShellHostModel, initialSelection: String? = nil) {
        self.model = model
        self.initialSelection = initialSelection
    }

    public var body: some View {
        LibraryView(games: model.details, controllers: model.controllers, actions: model.actions, input: model.input,
                    initialSelection: initialSelection)
            .sheet(item: $model.log) { LogView(log: $0) }
            .alert(Text(verbatim: hostText("Shell")), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button(hostText("OK")) { model.notice = nil }
            } message: { Text(model.notice ?? "") }
            .onAppear { model.startControllers() }
            .onDisappear { model.stopControllers() }
    }
}

/// A game's log, read-only.
struct LogView: View {
    let log: LogPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if log.truncated { Text(hostText("Only the end of the log is shown.")).font(.footnote).foregroundStyle(.secondary) }
                    Text(verbatim: log.text ?? hostText("This game has no log yet. It appears after the game has run."))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(log.text == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(log.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(hostText("Done")) { dismiss() }.accessibilityIdentifier("log.close") } }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("log.sheet")
    }
}
