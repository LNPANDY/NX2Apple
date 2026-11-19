import Foundation

/// The touch controls' groups as the game's layout editor places and sizes them (the engine's in-game menu: the gear › Controller layout ›
/// Adjust Gamepad Layout): the left shoulders (ZL, L, L3), the right ones (ZR, R, R3), the left stick, the D-pad, A B X Y, and − with the
/// menu button and +. The engine reads it as `DM_TOUCH_GROUPS` (`DmPadGeometry.h`, Groups): `1`, then per layout `;`, its name and its fields,
/// for example `1;3d/all:110/lshoulder:0,430,120/rshoulder:1000,430,120`:
/// - `all:<percent>`, every control's size (50 to 150) on top of the shell's Size,
/// - `solo:1`, the editor moves the left and right halves on their own (unset: mirrored),
/// - `<group>:<x>,<y>,<percent>`, where the group's box sits in the free range of its area, in thousandths (0 the left or top edge, 1000
///   the right or bottom edge), and its size in percent of the built-in size (50 to 200).
/// A place is relative to the safe area, so the same value fits every screen. It sits next to the single moves of `TouchLayout` (which stay
/// inside a group and go along with it) and is kept with them in the shell's settings; the shell's editor shows it and keeps it.
public struct TouchGroups: Equatable, Sendable {
    /// The groups in the engine's order (the order it places them). The raw values are the engine's names.
    public enum Group: String, CaseIterable, Sendable {
        case lshoulder, rshoulder, stick, dpad, face, center
        /// The engine's DM_PAD_G_* number.
        public var index: Int {
            switch self {
            case .lshoulder: 0
            case .rshoulder: 1
            case .stick: 2
            case .dpad: 3
            case .face: 4
            case .center: 5
            }
        }
        /// Drawn in this layout: the D-pad only in 3D.
        public func drawn(full: Bool) -> Bool { full || self != .dpad }
        /// The group a single control belongs to.
        public static func of(_ c: TouchLayout.Control) -> Group {
            switch c {
            case .zl, .l, .l3: .lshoulder
            case .zr, .r, .r3: .rshoulder
            case .stick: .stick
            case .dpad: .dpad
            case .minus, .plus: .center
            case .face, .a, .b, .x, .y: .face
            }
        }
    }

    public struct Place: Equatable, Hashable, Sendable {
        public var x: Int
        public var y: Int
        public var size: Int
        public init(x: Int, y: Int, size: Int) { self.x = x; self.y = y; self.size = size }
    }

    /// The engine's limits.
    public static let maxLength = 1024
    public static let anchorMax = 1000
    public static let sizes = 50...200
    public static let allSizes = 50...150

    private var places: [TouchLayout.Kind: [Group: Place]] = [:]
    private var allSize: [TouchLayout.Kind: Int] = [:]
    private var solos: Set<TouchLayout.Kind> = []

    public init() {}

    /// A group's place in one layout, nil where it is built in. A place out of the engine's range is kept inside it.
    public subscript(kind: TouchLayout.Kind, group: Group) -> Place? {
        get { places[kind]?[group] }
        set {
            var set = places[kind] ?? [:]
            set[group] = newValue.map {
                Place(x: min(Self.anchorMax, max(0, $0.x)), y: min(Self.anchorMax, max(0, $0.y)), size: min(Self.sizes.upperBound, max(Self.sizes.lowerBound, $0.size)))
            }
            places[kind] = set.isEmpty ? nil : set
        }
    }
    /// Every control's size in one layout, in percent (100: the shell's Size as it is).
    public func all(_ kind: TouchLayout.Kind) -> Int { allSize[kind] ?? 100 }
    public mutating func setAll(_ kind: TouchLayout.Kind, _ percent: Int) {
        let p = min(Self.allSizes.upperBound, max(Self.allSizes.lowerBound, percent))
        allSize[kind] = p == 100 ? nil : p
    }
    /// The editor moves the left and right halves on their own in this layout.
    public func solo(_ kind: TouchLayout.Kind) -> Bool { solos.contains(kind) }
    public mutating func setSolo(_ kind: TouchLayout.Kind, _ on: Bool) {
        if on { solos.insert(kind) } else { solos.remove(kind) }
    }

    /// No group placed and every size 100 (whether the halves move on their own is the editor's choice, not a place).
    public var isEmpty: Bool { places.isEmpty && allSize.isEmpty }
    public func isEmpty(_ kind: TouchLayout.Kind) -> Bool { places[kind] == nil && allSize[kind] == nil }
    /// Every group of one layout back where it is built in, every size back to 100, as the engine's Reset to default does.
    public mutating func reset(_ kind: TouchLayout.Kind) { places[kind] = nil; allSize[kind] = nil }
    /// The placed groups of one layout.
    public func placed(_ kind: TouchLayout.Kind) -> [Group: Place] { places[kind] ?? [:] }

    /// The value for `DM_TOUCH_GROUPS`, in the engine's order (`dm_pad_groups_encode`); empty when nothing differs from the built-in layout.
    public var encoded: String {
        var out = ""
        for kind in TouchLayout.Kind.allCases {
            let set = places[kind] ?? [:]
            guard !set.isEmpty || allSize[kind] != nil || solos.contains(kind) else { continue }
            if out.isEmpty { out = "1" }
            out += ";" + kind.rawValue
            if let a = allSize[kind] { out += "/all:\(a)" }
            if solos.contains(kind) { out += "/solo:1" }
            for group in Group.allCases { if let p = set[group] { out += "/\(group.rawValue):\(p.x),\(p.y),\(p.size)" } }
        }
        return out
    }

    /// Reads a value as the engine does (`dm_pad_groups_parse`): a layout, a group or a field with an unknown name is skipped, anything else
    /// that is not the form, a number out of range, or a value longer than the engine reads gives nil (the engine ignores it whole). Empty
    /// is the built-in layout.
    public init?(encoded value: String) {
        self.init()
        guard !value.isEmpty else { return }
        let b = Array(value.utf8)
        guard b.count <= Self.maxLength, b[0] == UInt8(ascii: "1"), b.count == 1 || b[1] == UInt8(ascii: ";") else { return nil }
        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        func isName(_ c: UInt8) -> Bool { (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || isDigit(c) }
        var i = 1
        while i < b.count, b[i] == UInt8(ascii: ";") {
            i += 1
            let nameStart = i
            while i < b.count, b[i] != UInt8(ascii: "/"), b[i] != UInt8(ascii: ";") { i += 1 }
            let kind = TouchLayout.Kind(rawValue: String(decoding: b[nameStart..<i], as: UTF8.self))
            while i < b.count, b[i] == UInt8(ascii: "/") {
                i += 1
                let start = i
                while i < b.count, isName(b[i]) { i += 1 }
                guard i > start, i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                let field = String(decoding: b[start..<i], as: UTF8.self)
                i += 1
                var numbers: [Int] = []
                while true {
                    guard numbers.count < 4 else { return nil }
                    var v = 0, digits = 0
                    while i < b.count, isDigit(b[i]) {
                        digits += 1
                        if digits > 4 { return nil }
                        v = v * 10 + Int(b[i] - UInt8(ascii: "0")); i += 1
                    }
                    guard digits > 0 else { return nil }
                    numbers.append(v)
                    if i < b.count, b[i] == UInt8(ascii: ",") { i += 1 } else { break }
                }
                if let group = Group(rawValue: field) {
                    guard numbers.count == 3, numbers[0] <= Self.anchorMax, numbers[1] <= Self.anchorMax, Self.sizes.contains(numbers[2]) else { return nil }
                    if let kind { self[kind, group] = Place(x: numbers[0], y: numbers[1], size: numbers[2]) }
                } else if field == "all" {
                    guard numbers.count == 1, Self.allSizes.contains(numbers[0]) else { return nil }
                    if let kind { setAll(kind, numbers[0]) }
                } else if field == "solo" {
                    guard numbers.count == 1, numbers[0] <= 1 else { return nil }
                    if let kind { setSolo(kind, numbers[0] == 1) }
                }
            }
            if i < b.count, b[i] != UInt8(ascii: ";") { return nil }
        }
        if i < b.count { return nil }
    }
}
