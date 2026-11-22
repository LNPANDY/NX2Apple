import SwiftUI
import ShellUI

/// `LibraryView` on a `ShellHostModel`: the real shell screen, plus the read-only log sheet and the notice alert. The
/// launch arguments of the demo (initial selection and so on) are not part of it.
public struct ShellHostView: View {
    private enum HostSheet: Identifiable {
        case cloudConflict(CloudSavePrompt)
        case log(LogPresentation)

        var id: String {
            switch self {
            case .cloudConflict(let prompt): "cloudConflict.\(prompt.id)"
            case .log(let log): "log.\(log.id)"
            }
        }
    }

    @Bindable private var model: ShellHostModel
    private let initialSelection: String?
    private let initialDetailOpen: Bool
    private let initialActivityLogOpen: Bool
    @State private var libraryModalPresented: Bool

    public init(model: ShellHostModel, initialSelection: String? = nil, initialDetailOpen: Bool = false, initialActivityLogOpen: Bool = false) {
        self.model = model
        self.initialSelection = initialSelection
        self.initialDetailOpen = initialDetailOpen
        self.initialActivityLogOpen = initialActivityLogOpen
        _libraryModalPresented = State(initialValue: initialDetailOpen)
    }

    private var activeHostSheet: HostSheet? {
        guard !libraryModalPresented else { return nil }
        if let prompt = model.cloudConflict { return .cloudConflict(prompt) }
        if let log = model.log { return .log(log) }
        return nil
    }

    private var activeNoticeHost: ShellNoticeHost {
        ShellNoticeHost.resolve(
            menuSheetPresented: libraryModalPresented,
            coverCropPresented: false,
            touchEditorPresented: false,
            hostSheetPresented: activeHostSheet != nil
        )
    }

    public var body: some View {
        Group {
            if model.isDeepLinkLaunching {
                Color.black.ignoresSafeArea()
                    .accessibilityIdentifier("deeplink.launching")
            } else {
                LibraryView(games: model.details, controllers: model.controllers, actions: model.actions, input: model.input,
                            initialSelection: initialSelection, initialDetailOpen: initialDetailOpen, globalPadMap: model.globalPadMap,
                            padMerge: model.padMerge, padSnapshot: model.padSnapshot,
                            signingWarning: model.signingWarning,
                            onDismissSigningWarning: { model.dismissSigningWarning() },
                            sideloadCertificate: model.sideloadCertificate,
                            canOpenHomeButtonSettings: model.canOpenHomeButtonSettings,
                            notice: model.notice,
                            noticeTitle: hostText("NX2Apple"),
                            noticeDismissTitle: hostText("OK"),
                            onDismissNotice: { model.notice = nil },
                            onModalPresentedChange: { libraryModalPresented = $0 },
                            activityLog: model.activityLog,
                            initialActivityLogOpen: initialActivityLogOpen)
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
            }
        }
            .sheet(item: Binding(
                get: { activeHostSheet },
                set: { newSheet in
                    guard newSheet == nil else { return }
                    if model.cloudConflict != nil {
                        model.cancelCloudConflictIfPending()
                        model.cloudConflict = nil
                    } else if model.log != nil {
                        model.log = nil
                    }
                }
            )) { sheet in
                Group {
                    switch sheet {
                    case .cloudConflict(let prompt):
                        ScrollView {
                            CloudSaveConflictView(prompt: prompt) { decision in
                                model.resolveCloudConflict(decision)
                            }
                        }
                        .presentationDetents([.medium, .large])
                        .presentationBackground(ShellPalette.background)
                    case .log(let log):
                        LogView(log: log)
                    }
                }
                .alert(
                    Text(verbatim: hostText("NX2Apple")),
                    isPresented: Binding(
                        get: { model.notice != nil && activeNoticeHost == .hostSheet },
                        set: { if !$0 { model.notice = nil } }
                    )
                ) {
                    Button(hostText("OK")) { model.notice = nil }
                } message: { Text(model.notice ?? "") }
            }
            .alert(
                Text(verbatim: hostText("NX2Apple")),
                isPresented: Binding(
                    get: { model.notice != nil && (model.isDeepLinkLaunching || activeNoticeHost == .root) },
                    set: { if !$0 { model.notice = nil } }
                )
            ) {
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
