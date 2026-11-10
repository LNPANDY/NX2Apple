import Foundation
import GameController
import IOKit.hid
import NXCore

extension Notification.Name {
    static let steamLinkPadsChanged = Notification.Name("NX2Apple.steamLinkPadsChanged")
    static let steamLinkPadInput = Notification.Name("NX2Apple.steamLinkPadInput")
}

/// A narrow, non-exclusive HID fallback for Steam's virtual Xbox 360 controllers (#797).
/// Main-run-loop confined. Never opens keyboards, physical pads, GC synthetic pads, or a device GC claims.
/// Games have their own controller reader, so this supplies launcher input only.
final class SteamLinkGamepads {
    static let shared = SteamLinkGamepads()

    struct Input {
        var id: String
        var state: SteamVirtualGamepad
    }

    private struct Device {
        var hid: IOHIDDevice
        var slot: Int
        var state = SteamVirtualGamepad()
        var values = 0
    }

    private var manager: IOHIDManager?
    private var devices: [String: Device] = [:]
    private var status: [String: String] = [:]
    private var managerResult: IOReturn = kIOReturnSuccess

    init(observeSystem: Bool = true) {
        guard observeSystem else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        // Matching is already restricted before we enumerate devices or receive any values.
        let matches = [4, 5, 8].map { usage in
            [kIOHIDVendorIDKey: 0x045e, kIOHIDProductIDKey: 0x028e,
             kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: usage]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, hid in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<SteamLinkGamepads>.fromOpaque(context).takeUnretainedValue().found(hid)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, hid in
            guard let context else { return }
            Unmanaged<SteamLinkGamepads>.fromOpaque(context).takeUnretainedValue().removed(hid)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        for device in devices.values { close(device.hid) }
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    var snapshots: [ConsolePadSnapshot] {
        devices.sorted { $0.value.slot < $1.value.slot }.map { id, device in
            Self.snapshot(id: id, slot: device.slot)
        }
    }

    static func snapshot(id: String, slot: Int) -> ConsolePadSnapshot {
        ConsolePadSnapshot(id: id, name: "GamePad-\(slot + 1)", category: "Xbox", playerIndex: nil,
                           battery: nil, canIdentify: false)
    }

    /// Only bounded device metadata and counts, never button histories, serials or environment variables.
    var diagnostics: [String] {
        ["GameController devices: \(GCController.controllers().count)",
         "Steam Link HID manager: \(manager == nil ? "not started" : String(format: "0x%08x", managerResult))",
         "Steam Link HID active: \(devices.count)"] + status.keys.sorted().compactMap { id in
            status[id].map { "\($0), input values: \(devices[id]?.values ?? 0)" }
        }
    }

    private func id(_ hid: IOHIDDevice) -> String {
        "steam-hid-" + String(UInt(bitPattern: Unmanaged.passUnretained(hid).toOpaque()), radix: 16)
    }

    private func found(_ hid: IOHIDDevice) {
        let id = id(hid)
        guard status[id] == nil else { return }
        func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(hid, key as CFString) as? NSNumber)?.intValue ?? 0 }
        let name = IOHIDDeviceGetProperty(hid, kIOHIDProductKey as CFString) as? String ?? ""
        guard let slot = SteamVirtualGamepad.slot(vendor: number(kIOHIDVendorIDKey), product: number(kIOHIDProductIDKey),
                                                  name: name, virtual: number(kIOHIDVirtualHIDevice) != 0,
                                                  synthetic: number("GCSyntheticDevice") != 0) else {
            status[id] = "045e:028e candidate: skipped, not a known Steam virtual identity (virtual \(number(kIOHIDVirtualHIDevice)), GC synthetic \(number("GCSyntheticDevice")))"
            return
        }
        let prefix = "GamePad-\(slot + 1) (045e:028e, version \(number(kIOHIDVersionNumberKey)))"
        guard !GCController.supportsHIDDevice(hid) else {
            status[id] = prefix + ": skipped, GameController claims device"
            return
        }
        let elements = IOHIDDeviceCopyMatchingElements(hid, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        let buttons = Set(elements.filter { IOHIDElementGetType($0) == kIOHIDElementTypeInput_Button &&
            IOHIDElementGetUsagePage($0) == 9 && IOHIDElementGetLogicalMin($0) == 0 && IOHIDElementGetLogicalMax($0) == 1
        }.map { Int(IOHIDElementGetUsage($0)) })
        let axes = Set(elements.filter { IOHIDElementGetUsagePage($0) == 1 &&
            [kIOHIDElementTypeInput_Axis, kIOHIDElementTypeInput_Misc].contains(IOHIDElementGetType($0)) &&
            !IOHIDElementIsRelative($0) && IOHIDElementGetLogicalMax($0) > IOHIDElementGetLogicalMin($0)
        }.map { Int(IOHIDElementGetUsage($0)) })
        guard buttons == Set(1...15), axes.contains(0x30), axes.contains(0x31) else {
            status[id] = prefix + ": skipped, unsupported layout (buttons \(buttons.sorted()), axes \(axes.sorted()))"
            return
        }
        let result = IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            status[id] = prefix + String(format: ": open failed 0x%08x", result)
            return
        }
        status[id] = prefix + ": raw HID, GameController does not claim device"
        devices[id] = Device(hid: hid, slot: slot)
        IOHIDDeviceRegisterInputValueCallback(hid, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<SteamLinkGamepads>.fromOpaque(context).takeUnretainedValue().read(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        NotificationCenter.default.post(name: .steamLinkPadsChanged, object: self)
    }

    private func read(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let hid = IOHIDElementGetDevice(element)
        let id = id(hid)
        guard var device = devices[id] else { return }
        let changed = device.state.update(page: Int(IOHIDElementGetUsagePage(element)), usage: Int(IOHIDElementGetUsage(element)),
                                          value: IOHIDValueGetIntegerValue(value), min: IOHIDElementGetLogicalMin(element),
                                          max: IOHIDElementGetLogicalMax(element))
        guard changed else { return }
        device.values += 1
        devices[id] = device
        NotificationCenter.default.post(name: .steamLinkPadInput, object: self, userInfo: ["input": Input(id: id, state: device.state)])
    }

    private func close(_ hid: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(hid, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func removed(_ hid: IOHIDDevice) {
        let id = id(hid)
        status.removeValue(forKey: id)
        guard let device = devices.removeValue(forKey: id) else { return }
        close(device.hid)
        NotificationCenter.default.post(name: .steamLinkPadsChanged, object: self, userInfo: ["removed": id])
    }
}
