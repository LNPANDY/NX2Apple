import Combine
import Foundation
import NXModel

extension LiveConsoleDriver {
    func dismissToast() { toastTask?.cancel(); notices.clear(); state.toast = nil; state.identifyingControllerID = nil }
    func exitToDesktop() { if state.pausedGameID != nil { state.askQuitPaused(then: .leave(selecting: nil)) } else { state.exitToDesktop() } }
    func returnFromGame() { state.returnFromGame() }

    /// A passing message goes through the one queue (ConsoleNotices.swift): one at a time, same kinds replace each other, none while a game starts.
    /// The top bar's activity chip follows the build store: the operation line and the current stage's share (ConsoleActivity).
    func bindActivity(_ build: BuildStore) {
        let update: () -> Void = { [weak self, weak build] in
            guard let self, let build else { return }
            guard build.running else { self.state.activity = nil; return }
            let title = build.operationTitle ?? build.t("library.preparing")
            let share = build.stages.last { $0.state == .running }?.percent.map { min(max($0 / 100, 0), 1) }
            self.state.activity = ConsoleActivity(title: title, stageProgress: share,
                                                  spokenProgress: share.map { String(format: build.t("console.stageProgress"), Int($0 * 100)) } ?? "")
        }
        build.$running.sink { _ in DispatchQueue.main.async(execute: update) }.store(in: &cancellables)
        build.$operation.sink { _ in DispatchQueue.main.async(execute: update) }.store(in: &cancellables)
        build.$stages.sink { _ in DispatchQueue.main.async(execute: update) }.store(in: &cancellables)
        update()
    }

    func showToast(_ message: String, glyph: ConsoleGlyphs.Glyph? = nil, kind: String = "general") {
        notices.post(kind: kind, message: message, glyph: glyph, now: Date(), suppressed: state.startingGame != nil)
        publishNotices()
    }

    func publishNotices() {
        notices.advance(now: Date(), suppressed: state.startingGame != nil)
        let shown = notices.current
        if state.toast?.id != shown?.id {
            state.toast = shown.map { ConsoleToast(id: $0.id, glyph: $0.glyph, message: $0.message) }
        }
        if shown == nil { state.identifyingControllerID = nil }
        toastTask?.cancel()
        guard let until = notices.until else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, until.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.publishNotices()
        }
    }
}
