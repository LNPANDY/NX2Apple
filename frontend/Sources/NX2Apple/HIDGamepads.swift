import Foundation
import GameController
import IOKit.hid
import NXCore

extension Notification.Name {
    static let hidPadsChanged = Notification.Name("NX2Apple.hidPadsChanged")
    static let hidPadInput = Notification.Name("NX2Apple.hidPadInput")
}

/// A narrow, non-exclusive raw-HID fallback for physical gamepads that GameController does not list.
/// On macOS 27 an 8BitDo Ultimate 2C over Bluetooth pairs, is seen by IOKit and never shows up in
/// `GCController.controllers()` (moonlight-stream/moonlight-qt#2017, the same regression Moonlight
/// works around with SDL_JOYSTICK_MFI=0), so the launcher and console showed no controller. Matching is
/// restricted before any device is opened: gamepads only (usage page 1, usage 5), never a virtual device
/// (Steam's virtual pads keep `SteamLinkGamepads`), never a GC synthetic device, and a device that
/// `GCController.supportsHIDDevice` claims is left alone unless a re-check confirms GameController
/// still lists no pad of this name (the call is a hint, not a claim: seedds/nxnative#965). Games have
/// their own controller reader, so this supplies launcher and console input only.
final class HIDGamepads {
    static let shared = HIDGamepads()

    struct Input {
        var id: String
        var state: HIDPadState
    }

    private struct Device {
        var hid: IOHIDDevice
        var name: String
        var state = HIDPadState()
        var values = 0
    }

    private var manager: IOHIDManager?
    private var devices: [String: Device] = [:]
    private var status: [String: String] = [:]
    private var waiting: [String: DispatchWorkItem] = [:]
    private var managerResult: IOReturn = kIOReturnSuccess

    init(observeSystem: Bool = true) {
        guard observeSystem else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        // Matching is already restricted before we enumerate devices or receive any values.
        let matches = [[kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 5] as [String: Int]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, hid in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDGamepads>.fromOpaque(context).takeUnretainedValue().found(hid)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, hid in
            guard let context else { return }
            Unmanaged<HIDGamepads>.fromOpaque(context).takeUnretainedValue().removed(hid)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        for device in devices.values { close(device.hid) }
        for item in waiting.values { item.cancel() }
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    var snapshots: [ConsolePadSnapshot] {
        devices.keys.sorted().compactMap { id in
            devices[id].map { ConsolePadSnapshot(id: id, name: $0.name.isEmpty ? "Game controller" : $0.name,
                                                 category: "Xbox", playerIndex: nil, battery: nil, canIdentify: false) }
        }
    }

    /// Only bounded device metadata and counts, never button histories, serials or environment variables.
    var diagnostics: [String] {
        ["HID fallback manager: \(manager == nil ? "not started" : String(format: "0x%08x", managerResult))",
         "HID fallback active: \(devices.count)"] + status.keys.sorted().compactMap { id in
            status[id].map { "\($0), input values: \(devices[id]?.values ?? 0)" }
        }
    }

    private func id(_ hid: IOHIDDevice) -> String {
        "hid-" + String(UInt(bitPattern: Unmanaged.passUnretained(hid).toOpaque()), radix: 16)
    }

    private func name(_ hid: IOHIDDevice) -> String {
        (IOHIDDeviceGetProperty(hid, kIOHIDProductKey as CFString) as? String) ?? ""
    }

    /// GameController owns every pad it lists under this device's name: only when it lists none of that
    /// name does the raw reader take the device.
    private func listedByGameController(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return GCController.controllers().contains { ($0.vendorName ?? "").contains(name) || name.contains($0.vendorName ?? "\u{0}") }
    }

    private func found(_ hid: IOHIDDevice) {
        let id = id(hid)
        guard status[id] == nil else { return }
        func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(hid, key as CFString) as? NSNumber)?.intValue ?? 0 }
        let name = name(hid)
        let prefix = "\(String(format: "%04x:%04x", number(kIOHIDVendorIDKey), number(kIOHIDProductIDKey))) \(name.isEmpty ? "(unnamed)" : name)"
        guard number(kIOHIDVirtualHIDevice) == 0, number("GCSyntheticDevice") == 0 else {
            status[id] = prefix + ": skipped, virtual device"
            return
        }
        let elements = IOHIDDeviceCopyMatchingElements(hid, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        let buttons = Set(elements.filter { IOHIDElementGetType($0) == kIOHIDElementTypeInput_Button &&
            IOHIDElementGetUsagePage($0) == 9 && IOHIDElementGetLogicalMin($0) == 0 && IOHIDElementGetLogicalMax($0) == 1
        }.map { Int(IOHIDElementGetUsage($0)) })
        let axes = Set(elements.filter { IOHIDElementGetUsagePage($0) == 1 &&
            [kIOHIDElementTypeInput_Axis, kIOHIDElementTypeInput_Misc].contains(IOHIDElementGetType($0)) &&
            !IOHIDElementIsRelative($0) && IOHIDElementGetLogicalMax($0) > IOHIDElementGetLogicalMin($0)
        }.map { Int(IOHIDElementGetUsage($0)) }.filter { [0x30, 0x31, 0x32, 0x33, 0x34, 0x35].contains($0) })
        let hats = elements.filter { IOHIDElementGetUsagePage($0) == 1 && Int(IOHIDElementGetUsage($0)) == 0x39 &&
            IOHIDElementGetLogicalMax($0) > IOHIDElementGetLogicalMin($0) }
        guard buttons.count >= 6, axes.count >= 2, !hats.isEmpty || axes.count >= 4 else {
            status[id] = prefix + ": skipped, not a readable gamepad layout (buttons \(buttons.count), axes \(axes.count), hat \(hats.count))"
            return
        }
        if GCController.supportsHIDDevice(hid) {
            // The call is a hint: wait out GameController's hotplug notification, then take the device
            // only if GameController still lists no pad of this name.
            status[id] = prefix + ": waiting for GameController's decision"
            let item = DispatchWorkItem { [weak self] in
                self?.claim(hid, id: id, prefix: prefix)
            }
            waiting[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
            return
        }
        claim(hid, id: id, prefix: prefix)
    }

    private func claim(_ hid: IOHIDDevice, id: String, prefix: String) {
        guard devices[id] == nil, let manager else { return }
        waiting.removeValue(forKey: id)
        guard !listedByGameController(name(hid)) else {
            status[id] = prefix + ": skipped, GameController lists a pad of this name"
            return
        }
        let result = IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            status[id] = prefix + String(format: ": open failed 0x%08x", result)
            return
        }
        status[id] = prefix + ": raw HID, GameController does not list it"
        devices[id] = Device(hid: hid, name: name(hid))
        IOHIDDeviceRegisterInputValueCallback(hid, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDGamepads>.fromOpaque(context).takeUnretainedValue().read(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        NotificationCenter.default.post(name: .hidPadsChanged, object: self)
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
        NotificationCenter.default.post(name: .hidPadInput, object: self, userInfo: ["input": Input(id: id, state: device.state)])
    }

    private func close(_ hid: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(hid, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func removed(_ hid: IOHIDDevice) {
        let id = id(hid)
        waiting.removeValue(forKey: id)?.cancel()
        status.removeValue(forKey: id)
        guard let device = devices.removeValue(forKey: id) else { return }
        close(device.hid)
        NotificationCenter.default.post(name: .hidPadsChanged, object: self, userInfo: ["removed": id])
    }
}
