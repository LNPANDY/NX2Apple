#if os(iOS)
import GameController
import ShellUI

/// Hardware adapter belongs to the demo, never ShellUI. The real shell can use its own adapter.
@MainActor final class DemoControllerInput {
    private var observers: [NSObjectProtocol] = []
    private var send: ((ShellInput.Action) -> Void)?
    private var heldDirection: ShellInput.Action?
    private var repeatTask: Task<Void, Never>?

    func start(send: @escaping (ShellInput.Action) -> Void) {
        stop()
        self.send = send
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bind() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.direction(nil) }
        })
        bind()
    }
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for controller in GCController.controllers() { controller.extendedGamepad?.valueChangedHandler = nil }
        repeatTask?.cancel()
        heldDirection = nil
        send = nil
    }
    private func bind() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, element in
                // GameController may call on its handler queue. Cross to the UI actor explicitly.
                let x = abs(pad.dpad.xAxis.value) > 0.4 ? pad.dpad.xAxis.value : pad.leftThumbstick.xAxis.value
                let y = abs(pad.dpad.yAxis.value) > 0.4 ? pad.dpad.yAxis.value : pad.leftThumbstick.yAxis.value
                let direction: ShellInput.Action? = abs(x) > abs(y) && abs(x) > 0.5 ? (x > 0 ? .right : .left) : abs(y) > 0.5 ? (y > 0 ? .up : .down) : nil
                let action: ShellInput.Action? = element == pad.buttonA && pad.buttonA.isPressed ? .activate
                    : element == pad.buttonB && pad.buttonB.isPressed ? .back
                    : element == pad.buttonX && pad.buttonX.isPressed ? .settings
                    : element == pad.buttonY && pad.buttonY.isPressed ? .controllers : nil
                Task { @MainActor in
                    self?.direction(direction)
                    if let action { self?.send?(action) }
                }
            }
        }
    }
    private func direction(_ action: ShellInput.Action?) {
        guard action != heldDirection else { return }
        repeatTask?.cancel()
        heldDirection = action
        guard let action else { return }
        send?(action)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled {
                self?.send?(action)
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }
}
#endif
