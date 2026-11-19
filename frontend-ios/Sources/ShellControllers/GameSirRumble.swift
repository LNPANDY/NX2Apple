#if os(iOS)
import ExternalAccessory
import Foundation
import GameController
import UIKit

/// The wired G8+ MFi exposes its two grip motors on this accessory protocol.
/// Packet and device identifiers verified in VoidLink PR 214.
@MainActor @objc(NXShellControllerRumble)
final class GameSirRumble: NSObject, @preconcurrency StreamDelegate {
    static let shared = GameSirRumble()
    private static let accessoryProtocol = "com.xiaoji.M2boot"

    @objc(handlesController:) nonisolated static func handles(_ pad: GCController) -> Bool {
        guard pad.isAttachedToDevice, let name = pad.vendorName?.lowercased() else { return false }
        return name.contains("gamesir") && name.contains("g8+") && name.contains("mfi")
    }

    // Called in order on the game framework's serial rumble queue. Only the main run loop owns the streams.
    @objc(setController:left:right:) nonisolated static func setController(_ pad: GCController, left: Float, right: Float) {
        let id = ObjectIdentifier(pad)
        func byte(_ level: Float) -> UInt8 { UInt8((max(0, min(1, level)) * 255).rounded()) }
        let l = byte(left), r = byte(right)
        DispatchQueue.main.async { shared.playGame(id, left: l, right: r) }
    }

    private var session: EASession?
    private var owner: ObjectIdentifier?
    private var retryAfter = Date.distantPast
    private var motors = GameSirMotorOutput()
    private var testID: UUID?
    private var testWaiter: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(resign), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(accessoryGone(_:)), name: .EAAccessoryDidDisconnect, object: nil)
        center.addObserver(self, selector: #selector(controllerGone(_:)), name: .GCControllerDidDisconnect, object: nil)
        EAAccessoryManager.shared().registerForLocalNotifications()
    }

    private func open(_ id: ObjectIdentifier) -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        if session != nil { return owner == id }
        guard Date.now >= retryAfter else { return false }
        retryAfter = Date.now.addingTimeInterval(1)
        let pads = GCController.controllers().filter(Self.handles)
        let devices = EAAccessoryManager.shared().connectedAccessories.filter {
            $0.isConnected && $0.manufacturer.caseInsensitiveCompare("GameSir") == .orderedSame
                && $0.modelNumber.caseInsensitiveCompare("G8+ MFi") == .orderedSame
                && $0.protocolStrings.contains(Self.accessoryProtocol)
        }
        guard pads.count == 1, ObjectIdentifier(pads[0]) == id, devices.count == 1 else {
            return false
        }
        guard let next = EASession(accessory: devices[0], forProtocol: Self.accessoryProtocol),
              let input = next.inputStream, let output = next.outputStream else {
            return false
        }
        session = next
        owner = id
        for stream in [input as Stream, output as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
        return session != nil
    }

    func test(_ pad: GCController, left: UInt8, right: UInt8) async -> Bool {
        cancelTest()
        retryAfter = .distantPast
        guard open(ObjectIdentifier(pad)) else { return false }
        let id = UUID()
        testID = id
        motors.set(left: left, right: right)
        let written = await withCheckedContinuation { continuation in
            testWaiter = continuation
            timer = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, testID == id else { return }
                close()
            }
            drain()
        }
        if written, testID == id {
            timer?.cancel()
            timer = Task {
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled, testID == id else { return }
                cancelTest()
            }
        }
        return written
    }

    func cancelTest() {
        guard testID != nil else { return }
        finishTest()
        motors.set(left: 0, right: 0)
        drain()
    }

    private func finishTest() {
        testID = nil
        timer?.cancel()
        timer = nil
        testWaiter?.resume(returning: false)
        testWaiter = nil
    }

    private func playGame(_ id: ObjectIdentifier, left: UInt8, right: UInt8) {
        if left == 0 && right == 0 {
            guard owner == id, testID == nil else { return }
        } else {
            guard open(id) else { return }
            if testID != nil { finishTest() }
        }
        motors.set(left: left, right: right)
        drain()
    }

    private func drain() {
        guard let output = session?.outputStream, output.streamStatus == .open else { return }
        while !motors.delivered && output.hasSpaceAvailable {
            let n = motors.writeNext { output.write($0.baseAddress!, maxLength: $0.count) }
            if n < 0 {
                close()
                return
            }
            if n == 0 { return }
        }
        if testWaiter != nil, motors.delivered {
            testWaiter?.resume(returning: true)
            testWaiter = nil
        }
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        guard let session, stream === session.inputStream || stream === session.outputStream else { return }
        switch event {
        case .errorOccurred, .endEncountered:
            close()
        case .openCompleted, .hasSpaceAvailable: drain()
        case .hasBytesAvailable:
            guard let input = stream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 256)
            while input.hasBytesAvailable {
                let n = input.read(&buffer, maxLength: buffer.count)
                if n <= 0 { if n < 0 { close() }; break }
            }
        default: break
        }
    }

    @objc private func resign() {
        finishTest()
        motors.set(left: 0, right: 0)
        drain()
        close()
    }

    @objc private func accessoryGone(_ note: Notification) {
        if let device = note.userInfo?[EAAccessoryKey] as? EAAccessory,
           device.connectionID == session?.accessory?.connectionID { close() }
    }

    @objc private func controllerGone(_ note: Notification) {
        if let pad = note.object as? GCController, ObjectIdentifier(pad) == owner { resign() }
    }

    private func close() {
        finishTest()
        let previous = session
        session = nil
        owner = nil
        for case let stream? in [previous?.inputStream as Stream?, previous?.outputStream as Stream?] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .common)
        }
        motors = GameSirMotorOutput()
    }
}
#endif

/// A stream may accept part of a report. Finish that report before sending the most recent motor state.
struct GameSirMotorOutput {
    private var desired: [UInt8] = [4, 0, 1, 0, 1, 0, 0, 0, 0]
    private var sent: [UInt8] = []
    private var frame: [UInt8] = []
    private var offset = 0

    var delivered: Bool { offset == 0 && sent == desired }

    mutating func set(left: UInt8, right: UInt8) {
        desired[1] = left
        desired[3] = right
    }

    mutating func writeNext(_ write: (UnsafeBufferPointer<UInt8>) -> Int) -> Int {
        if delivered { return 0 }
        if offset == 0 { frame = desired }
        let n = frame.withUnsafeBufferPointer { write(UnsafeBufferPointer(rebasing: $0[offset...])) }
        guard n > 0 else { return n }
        offset += n
        if offset == frame.count { sent = frame; offset = 0 }
        return n
    }
}
