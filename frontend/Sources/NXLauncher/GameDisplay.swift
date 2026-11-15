import AppKit
import CoreGraphics

package enum GameDisplay {
    package static let defaultsKey = "gameDisplayUUID"

    package static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
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
