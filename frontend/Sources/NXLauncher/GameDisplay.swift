import AppKit
import CoreGraphics

package enum GameDisplay {
    package static let defaultsKey = "gameDisplayUUID"

    /// A screen's UUID asks the window server, which blocks the main thread on every call. Settings draws the Display row on every
    /// redraw, so the answer is kept per display until the screens change.
    package static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = number.uint32Value
        _ = screensChanged
        lock.lock(); defer { lock.unlock() }
        if let text = known[id] { return text }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let text = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
        known[id] = text
        return text
    }

    private static let lock = NSLock()
    private static var known: [UInt32: String] = [:]
    private static let screensChanged: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { _ in
        lock.lock(); known = [:]; lock.unlock()
    }

    package static func displayID(savedUUID: String, launcher: NSScreen?, screens: [NSScreen]) -> UInt32? {
        let available = screens.compactMap { screen -> (uuid: String, id: UInt32)? in
            guard let uuid = uuid(of: screen), let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (uuid, id.uint32Value)
        }
        let launcherID = (launcher?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return displayID(savedUUID: savedUUID, launcherID: launcherID, available: available)
    }

    package static func displayID(savedUUID: String, launcherID: UInt32?, available: [(uuid: String, id: UInt32)]) -> UInt32? {
        available.first { !savedUUID.isEmpty && $0.uuid == savedUUID }?.id ?? launcherID
    }
}
