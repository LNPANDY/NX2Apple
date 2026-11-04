import SwiftUI
import ShellUI

/// `LibraryView` on a `ShellHostModel`: the real shell screen, plus the read-only log sheet and the notice alert. The
/// launch arguments of the demo (initial selection and so on) are not part of it.
public struct ShellHostView: View {
    @Bindable private var model: ShellHostModel
    private let initialSelection: String?
    private let initialDetailOpen: Bool

    public init(model: ShellHostModel, initialSelection: String? = nil, initialDetailOpen: Bool = false) {
        self.model = model
        self.initialSelection = initialSelection
        self.initialDetailOpen = initialDetailOpen
    }

    public var body: some View {
        LibraryView(games: model.details, controllers: model.controllers, actions: model.actions, input: model.input,
                    initialSelection: initialSelection, initialDetailOpen: initialDetailOpen, globalPadMap: model.globalPadMap,
                    padSnapshot: model.padSnapshot)
            .disabled(model.launchingGame)
            .overlay {
                if model.launchingGame {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        ProgressView { Text("Preparing game…", bundle: .module) }
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityIdentifier("launch.progress")
                    }
                }
            }
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
