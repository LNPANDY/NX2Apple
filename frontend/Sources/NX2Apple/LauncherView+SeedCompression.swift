import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Wiring and startup hook for build-seed zstd compression sheet, keeping `LauncherView.swift` within the 800-line limit.
extension LauncherView {
    func runSeedCompressionStartupCheck() {
        guard performStartupChecks,
              !m.running,
              !stores.queue.active,
              !stores.transfers.entries.contains(where: \.active),
              !launching,
              libraryInputAvailable else { return }
        let tool = SeedCompression.toolPath(repoPath: stores.repo.path)
        guard !tool.isEmpty, FileManager.default.fileExists(atPath: tool) else { return }
        stores.seedCompression.scanOnStartupIfNeeded()
    }

    func handleSeedCompressionPadBack() {
        switch stores.seedCompression.phase {
        case .prompt:
            stores.seedCompression.dismissPrompt(dontAskAgain: false)
        case .done:
            stores.seedCompression.finishDone()
        case .running, nil:
            break
        }
    }
}

extension View {
    func seedCompressionSheet(
        _ store: SeedCompressionStore,
        library: GameLibrary,
        loc: Localizer,
        pad: PadFocus,
        scope: @escaping () -> String
    ) -> some View {
        self.sheet(isPresented: Binding(
            get: { store.phase != nil },
            set: { open in
                guard !open else { return }
                switch store.phase {
                case .prompt: store.dismissPrompt(dontAskAgain: false)
                case .done: store.finishDone()
                case .running, nil: break
                }
            }
        )) {
            SeedCompressionSheet(store: store) { tid in
                library.games.first { $0.titleID.uppercased() == tid }?.displayName(loc.lang)
            }
            .interactiveDismissDisabled(store.isRunning)
            .environmentObject(loc)
            .environmentObject(pad)
        }
        .onChange(of: store.phase != nil) { open in
            pad.scope = open ? "seedCompress" : scope()
        }
    }
}
