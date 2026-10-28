import Foundation
import IOKit
import os

/// Tells the launcher when a game pad, joystick or multi-axis controller is plugged in or removed, straight from the IOKit registry
/// (matching notifications on IOHIDDevice with the Generic Desktop usages GamePad, Joystick and MultiAxisController). It only watches
/// the registry: no device is opened or seized, so games and the system are unaffected and no permission is asked. It exists because
/// GameController can report a controller seconds after the hardware appears, and sometimes not on a re-plug. The launcher shows a
/// "Connecting" placeholder from this and replaces it when GameController reports the controller.
final class HIDControllerWatcher {
    struct Event: Equatable {
        enum Kind { case attach, detach }
        var kind: Kind
        var id: UInt64
        var name: String
    }

    private static let log = Logger(subsystem: "NX2Apple", category: "console.controllers")
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var seen = Set<UInt64>()
    private let handler: (Event) -> Void

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for usage in [5, 4, 8] {   // GamePad, Joystick, MultiAxisController
            for (notification, attach) in [(kIOFirstMatchNotification, true), (kIOTerminatedNotification, false)] {
                let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
                matching["DeviceUsagePage"] = 1
                matching["DeviceUsage"] = usage
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(port, notification, matching, attach ? Self.attachCallback : Self.detachCallback, refcon, &iterator)
                if status == KERN_SUCCESS {
                    iterators.append(iterator)
                    drain(iterator, attach: attach)   // arms the notification and reports what is already there
                }
            }
        }
    }

    private static let attachCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<HIDControllerWatcher>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, attach: true)
    }
    private static let detachCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<HIDControllerWatcher>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, attach: false)
    }

    private func drain(_ iterator: io_iterator_t, attach: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            let name = (IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
            if attach { guard seen.insert(id).inserted else { continue } } else { guard seen.remove(id) != nil else { continue } }
            Self.log.debug("hid \(attach ? "attach" : "detach", privacy: .public) \(name, privacy: .public) id \(id) at \(Date().timeIntervalSince1970, format: .fixed(precision: 3))")
            handler(Event(kind: attach ? .attach : .detach, id: id, name: name))
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }
}

/// Which controllers the launcher shows while the hardware and GameController disagree: a "Connecting" placeholder from a plug-in
/// until GameController reports it (or ten seconds pass), and a controller hidden from its unplug until GameController lets go of it.
/// Names are compared loosely (the HID product is often a part of GameController's vendor name).
struct HIDPresence {
    struct Pending: Equatable { var id: UInt64; var name: String; var since: Date }
    private(set) var pending: [Pending] = []
    private(set) var detached: [String] = []
    static let timeout: TimeInterval = 10

    static func matches(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }

    mutating func attached(id: UInt64, name: String, at now: Date = Date()) {
        detached.removeAll { Self.matches($0, name) }   // plugged in again: GameController's old object, if any, shows again
        if !pending.contains(where: { $0.id == id }) { pending.append(Pending(id: id, name: name, since: now)) }
    }

    mutating func detached(id: UInt64, name: String) {
        let hadPlaceholder = pending.contains { $0.id == id }
        pending.removeAll { $0.id == id }
        if hadPlaceholder { return }   // GameController never knew it: nothing to hide
        if !name.isEmpty, !detached.contains(where: { Self.matches($0, name) }) { detached.append(name) }
    }

    /// GameController reported a controller: its placeholder (the one with a matching name, else the oldest) is replaced.
    /// Without a name match the oldest placeholder goes, only when `orOldest` (a connect notification, not a list read).
    mutating func gcConnected(name: String, orOldest: Bool = true) {
        if let i = pending.firstIndex(where: { Self.matches($0.name, name) }) ?? (orOldest ? pending.indices.first : nil) { pending.remove(at: i) }
    }

    /// GameController let go of a controller: it no longer needs hiding.
    mutating func gcDisconnected(name: String) { detached.removeAll { Self.matches($0, name) } }

    mutating func expire(now: Date = Date()) { pending.removeAll { now.timeIntervalSince($0.since) >= Self.timeout } }

    func isHidden(_ gcName: String) -> Bool { detached.contains { Self.matches($0, gcName) } }
}
