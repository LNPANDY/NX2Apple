import Foundation
import IOKit

/// Physical link profile of a paired iOS device for game data transfer estimation and guidance.
package enum DeviceLinkProfile: Equatable, Sendable {
    case highSpeedUSB(bps: Int64)
    case usb2(bps: Int64)
    case wifi
    case wiredUnknown
    case disconnected

    package var isWired: Bool {
        switch self {
        case .highSpeedUSB, .usb2, .wiredUnknown: return true
        case .wifi, .disconnected: return false
        }
    }

    package var isHighSpeedUSB: Bool {
        if case .highSpeedUSB = self { return true }
        return false
    }

    package var isUSB2: Bool {
        if case .usb2 = self { return true }
        return false
    }

    package var isConnected: Bool {
        self != .disconnected
    }

    package var rateText: String? {
        switch self {
        case .highSpeedUSB(let bps), .usb2(let bps):
            return USBLinkSpeed.formatRate(bps)
        case .wifi, .wiredUnknown, .disconnected:
            return nil
        }
    }
}

/// Strategy for transferring game data to the device after a direct-install iOS build finishes.
package enum PostBuildTransferMode: String, CaseIterable, Equatable, Sendable {
    case ask = "ask"
    case auto = "auto"
    case skip = "skip"

    package static let defaultMode: PostBuildTransferMode = .ask

    package static func fromStored(_ raw: String?) -> PostBuildTransferMode {
        guard let raw, let parsed = PostBuildTransferMode(rawValue: raw) else { return defaultMode }
        return parsed
    }
}

/// Queries IOKit USB host device entries to detect physical negotiated link speed for a device UDID.
package enum USBLinkSpeed {
    /// 5 Gbps threshold separating SuperSpeed (USB 3 / Thunderbolt) from USB 2.0 (480 Mbps).
    package static let highSpeedThresholdBps: Int64 = 5_000_000_000

    /// Strips hyphens and whitespace and uppercases a UDID / USB serial number for case-insensitive matching.
    package static func normalizeUDID(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
    }

    /// Queries the live IOKit registry for the physical USB link speed (in bits per second) of `udid`.
    package static func linkSpeedBps(forUDID udid: String) -> Int64? {
        let target = normalizeUDID(udid)
        guard !target.isEmpty else { return nil }
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let bps = speedBps(inService: service, normalizedUDID: target) {
                return bps
            }
        }
        return nil
    }

    private static func speedBps(inService service: io_registry_entry_t, normalizedUDID target: String) -> Int64? {
        if let props = properties(of: service), matchesUDID(normalizedUDID: target, properties: props) {
            if let bps = extractSpeedBps(from: props) {
                return bps
            }
            if let fallback = inheritedSpeedBps(of: service) {
                return fallback
            }
        }
        // Check direct / nested child entries if a composite hub/device nests the serial under a child.
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        while true {
            let child = IOIteratorNext(childIterator)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            if let childProps = properties(of: child), matchesUDID(normalizedUDID: target, properties: childProps) {
                if let bps = extractSpeedBps(from: childProps) {
                    return bps
                }
                if let parentProps = properties(of: service), let bps = extractSpeedBps(from: parentProps) {
                    return bps
                }
                if let fallback = inheritedSpeedBps(of: child) {
                    return fallback
                }
            }
        }
        return nil
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func inheritedSpeedBps(of entry: io_registry_entry_t) -> Int64? {
        let searchOptions: [IOOptionBits] = [
            IOOptionBits(kIORegistryIterateRecursively),
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents),
        ]
        for options in searchOptions {
            for key in ["UsbLinkSpeed", "USBSpeed", "Device Speed"] {
                if let raw = IORegistryEntrySearchCFProperty(
                    entry,
                    kIOServicePlane,
                    key as CFString,
                    kCFAllocatorDefault,
                    options
                ) {
                    if let bps = extractSpeedBps(from: [key: raw]) {
                        return bps
                    }
                }
            }
        }
        return nil
    }

    /// Pure matcher for testing IOKit property dictionaries against a device UDID.
    package static func matchesUDID(_ udid: String, properties: [String: Any]) -> Bool {
        let target = normalizeUDID(udid)
        guard !target.isEmpty else { return false }
        return matchesUDID(normalizedUDID: target, properties: properties)
    }

    private static func matchesUDID(normalizedUDID target: String, properties: [String: Any]) -> Bool {
        for key in ["kUSBSerialNumberString", "USB Serial Number"] {
            if let serial = properties[key] as? String, normalizeUDID(serial) == target {
                return true
            }
        }
        return false
    }

    /// Pure parser extracting negotiated link speed in bits per second from IOKit properties.
    /// - `"UsbLinkSpeed"`: direct speed in bits/sec (e.g. `10_000_000_000` for 10 Gbps, `480_000_000` for 480 Mbps).
    /// - `"USBSpeed"` (`IOKit/usb/IOUSBHostFamilyDefinitions.h` `tIOUSBHostConnectionSpeed`, 1-based):
    ///   `1 = Full (12M)`, `2 = Low (1.5M)`, `3 = High (480M)`, `4 = Super (5G)`, `5 = Super+ (10G)`, `6 = Super+ 2x2 (20G)`.
    /// - `"Device Speed"` (`IOKit/usb/USB.h` `kUSBDeviceSpeed*`, 0-based):
    ///   `0 = Low (1.5M)`, `1 = Full (12M)`, `2 = High (480M)`, `3 = Super (5G)`, `4 = Super+ (10G)`, `5 = Super+ 2x2 (20G)`.
    package static func extractSpeedBps(from properties: [String: Any]) -> Int64? {
        if let raw = int64Value(properties["UsbLinkSpeed"]), raw > 0 {
            return raw
        }
        if let raw = int64Value(properties["USBSpeed"]) {
            if raw >= 1_000_000 { return raw }
            switch raw {
            case 1: return 12_000_000         // Full Speed (12 Mbps)
            case 2: return 1_500_000          // Low Speed (1.5 Mbps)
            case 3: return 480_000_000        // High Speed (480 Mbps)
            case 4: return 5_000_000_000      // SuperSpeed (5 Gbps)
            case 5: return 10_000_000_000     // SuperSpeed+ (10 Gbps)
            case 6: return 20_000_000_000     // SuperSpeed+ Gen2x2 (20 Gbps)
            default: break
            }
        }
        if let raw = int64Value(properties["Device Speed"]) {
            if raw >= 1_000_000 { return raw }
            switch raw {
            case 0: return 1_500_000          // Low Speed (1.5 Mbps)
            case 1: return 12_000_000         // Full Speed (12 Mbps)
            case 2: return 480_000_000        // High Speed (480 Mbps)
            case 3: return 5_000_000_000      // SuperSpeed (5 Gbps)
            case 4: return 10_000_000_000     // SuperSpeed+ (10 Gbps)
            case 5: return 20_000_000_000     // SuperSpeed+ Gen2x2 (20 Gbps)
            default: break
            }
        }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let num = value as? NSNumber { return num.int64Value }
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let u = value as? UInt64 { return u <= UInt64(Int64.max) ? Int64(u) : Int64.max }
        if let s = value as? String { return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// Combines `devicectl` connection state with IOKit USB link speed into a unified profile.
    package static func profile(connection: ShellConnection, usbSpeedBps: Int64?) -> DeviceLinkProfile {
        switch connection {
        case .wired:
            guard let bps = usbSpeedBps, bps > 0 else { return .wiredUnknown }
            return bps >= highSpeedThresholdBps ? .highSpeedUSB(bps: bps) : .usb2(bps: bps)
        case .network:
            return .wifi
        case .other:
            if let bps = usbSpeedBps, bps > 0 {
                return bps >= highSpeedThresholdBps ? .highSpeedUSB(bps: bps) : .usb2(bps: bps)
            }
            return .wiredUnknown
        case .notConnected, .notPaired:
            return .disconnected
        }
    }

    /// Combines an `AppleDevice` listing record with IOKit USB link speed into a unified profile.
    package static func profile(for device: AppleDevice?, usbSpeedBps: Int64?) -> DeviceLinkProfile {
        guard let device else { return .disconnected }
        if device.wired {
            return profile(connection: .wired, usbSpeedBps: usbSpeedBps)
        }
        if device.overNetwork {
            return .wifi
        }
        if device.reachable {
            return profile(connection: .other, usbSpeedBps: usbSpeedBps)
        }
        return .disconnected
    }

    /// Human-readable link rate string such as "10 Gbps", "5 Gbps", or "480 Mbps".
    package static func formatRate(_ bps: Int64) -> String {
        if bps >= 1_000_000_000 {
            let gbps = Double(bps) / 1_000_000_000.0
            if bps % 1_000_000_000 == 0 {
                return "\(bps / 1_000_000_000) Gbps"
            }
            return String(format: "%.1f Gbps", gbps)
        }
        if bps >= 1_000_000 {
            if bps % 1_000_000 == 0 {
                return "\(bps / 1_000_000) Mbps"
            }
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000.0)
        }
        return "\(max(1, bps / 1_000)) Kbps"
    }

    /// Estimated transfer duration in minutes for `bytes` over `profile`, or nil when unknown/disconnected.
    /// Effective throughput ranges:
    /// - High-speed USB (5/10 Gbps): ~110–130 MB/s
    /// - USB 2.0 (480 Mbps): ~28–35 MB/s
    /// - Wi-Fi (localNetwork): ~17–25 MB/s
    package static func estimateMinutes(bytes: Int64, profile: DeviceLinkProfile) -> (low: Int, high: Int)? {
        guard bytes > 0 else { return nil }
        let throughput: (low: Double, high: Double)
        switch profile {
        case .highSpeedUSB:
            throughput = (110e6, 130e6)
        case .usb2:
            throughput = (28e6, 35e6)
        case .wifi:
            throughput = (17e6, 25e6)
        case .wiredUnknown, .disconnected:
            return nil
        }
        let low = max(1, Int((Double(bytes) / throughput.high / 60.0).rounded()))
        let high = max(low, Int((Double(bytes) / throughput.low / 60.0).rounded()))
        return (low, high)
    }
}
