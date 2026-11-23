import Foundation

/// Four-tier compatibility classification for an Atmosphere cheat entry on iOS and Mac.
package enum CheatCapability: String, Equatable, Sendable {
    /// Writes only to writable game memory (main .data/.bss or pointer-resolved heap): works directly on iOS without re-baking.
    case dataReady
    /// Modifies executable game code (or conditional code) and has offline trampolines baked into the current framework.
    case codeBaked
    /// Modifies executable game code (off < main_rx_end or dynamic main write) and has not yet been baked into the current framework.
    case codeNeedsBake
    /// Writes to a hardcoded non-zero heap offset that may shift across saves or scenes (still switchable directly on iOS).
    case fixedHeapWarning
}

/// Metadata parsed from `dm/main.fixups.tsv`.
package struct CheatMainFixupsMetadata: Equatable, Sendable {
    package var buildID: String?
    package var mainRxEnd: UInt64?

    package init(buildID: String? = nil, mainRxEnd: UInt64? = nil) {
        self.buildID = buildID
        self.mainRxEnd = mainRxEnd
    }

    package static func parse(_ text: String) -> CheatMainFixupsMetadata {
        var buildID: String?
        var mainRxEnd: UInt64?
        var textEnd: UInt64?

        for rawLine in text.split(whereSeparator: \.isNewline) where rawLine.hasPrefix("#") {
            let fields = rawLine.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            switch fields[0] {
            case "BUILD_ID":
                if buildID == nil, fields[1].count >= 16, fields[1].prefix(16).allSatisfy(\.isHexDigit) {
                    buildID = fields[1].prefix(16).uppercased()
                }
            case "MAIN_RX_END":
                if let value = parseHexOrDec(fields[1]) {
                    mainRxEnd = value
                }
            case "TEXT_END":
                if let value = parseHexOrDec(fields[1]) {
                    textEnd = value
                }
            default:
                break
            }
        }
        if mainRxEnd == nil, let textEnd, textEnd > 0 {
            mainRxEnd = (textEnd &+ 0x3FFF) & ~UInt64(0x3FFF)
        }
        return CheatMainFixupsMetadata(buildID: buildID, mainRxEnd: mainRxEnd)
    }

    package static func parseHexOrDec<S: StringProtocol>(_ raw: S) -> UInt64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed, radix: 10)
    }
}

/// Metadata parsed from `dm/cheat_trampolines.tsv` emitted by `dm/tools/cheat_bake.py`.
package struct CheatTrampolineMetadata: Equatable, Sendable {
    package struct EntryRecord: Equatable, Sendable {
        package var kind: String
        package var keyMask: UInt64
        package var detail: String

        package init(kind: String, keyMask: UInt64 = 0, detail: String = "") {
            self.kind = kind
            self.keyMask = keyMask
            self.detail = detail
        }

        package var isBaked: Bool {
            kind == "baked_static" || kind == "baked_conditional"
        }
    }

    package var buildID: String?
    package var mainRxEnd: UInt64?
    package var slotsUsed: Int
    package var entries: [String: EntryRecord]
    package var bakedSiteKeys: Set<String>

    package init(
        buildID: String? = nil,
        mainRxEnd: UInt64? = nil,
        slotsUsed: Int = 0,
        entries: [String: EntryRecord] = [:],
        bakedSiteKeys: Set<String> = []
    ) {
        self.buildID = buildID
        self.mainRxEnd = mainRxEnd
        self.slotsUsed = slotsUsed
        self.entries = entries
        self.bakedSiteKeys = bakedSiteKeys
    }

    package static func parse(_ text: String) -> CheatTrampolineMetadata {
        var buildID: String?
        var mainRxEnd: UInt64?
        var slotsUsed = 0
        var entries: [String: EntryRecord] = [:]
        var bakedSiteKeys = Set<String>()
        var colMap: [String: Int]?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            if rawLine.hasPrefix("#") {
                let fields = rawLine.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2 else { continue }
                switch fields[0] {
                case "BUILD_ID":
                    if fields[1].count >= 16, fields[1].prefix(16).allSatisfy(\.isHexDigit) {
                        buildID = fields[1].prefix(16).uppercased()
                    }
                case "MAIN_RX_END":
                    mainRxEnd = CheatMainFixupsMetadata.parseHexOrDec(fields[1])
                case "SLOTS_USED":
                    slotsUsed = Int(fields[1]) ?? 0
                default:
                    break
                }
                continue
            }
            let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard !cols.isEmpty else { continue }
            if colMap == nil {
                if cols[0] == "row_type" {
                    var map: [String: Int] = [:]
                    for (idx, name) in cols.enumerated() { map[name] = idx }
                    colMap = map
                    continue
                }
                // Fallback to canonical column positions if header line was omitted.
                colMap = [
                    "row_type": 0, "name": 1, "cheat_key": 2, "kind": 3,
                    "slot_id": 4, "variant_mask": 5, "target_off": 6,
                    "patched_word": 7, "key_mask": 8, "detail": 9,
                ]
            }
            guard let map = colMap else { continue }
            func field(_ name: String) -> String {
                guard let idx = map[name], idx < cols.count else { return "" }
                return cols[idx]
            }
            let rowType = field("row_type")
            let cheatKey = field("cheat_key")
            guard !cheatKey.isEmpty else { continue }
            let kind = field("kind")
            let keyMask = CheatMainFixupsMetadata.parseHexOrDec(field("key_mask")) ?? 0
            let detail = field("detail")

            if rowType == "entry" {
                entries[cheatKey] = EntryRecord(kind: kind, keyMask: keyMask, detail: detail)
            } else if rowType == "site" {
                bakedSiteKeys.insert(cheatKey)
                if let existing = entries[cheatKey] {
                    entries[cheatKey] = EntryRecord(
                        kind: existing.isBaked ? existing.kind : kind,
                        keyMask: existing.keyMask | keyMask,
                        detail: existing.detail
                    )
                } else {
                    entries[cheatKey] = EntryRecord(kind: kind, keyMask: keyMask, detail: detail)
                }
            }
        }
        return CheatTrampolineMetadata(
            buildID: buildID,
            mainRxEnd: mainRxEnd,
            slotsUsed: slotsUsed,
            entries: entries,
            bakedSiteKeys: bakedSiteKeys
        )
    }

    package func record(forKey key: String) -> EntryRecord? {
        entries[key]
    }

    package func isBaked(key: String) -> Bool {
        if bakedSiteKeys.contains(key) { return true }
        return entries[key]?.isBaked ?? false
    }
}

/// Maps Atmosphère Opcode 8 / C4 Switch NpadButton bitmasks to concise button names matching `hle_hid.c`.
package enum CheatKeyMask {
    private static let buttonLabels: [(bit: Int, label: String)] = [
        (0, "A"),
        (1, "B"),
        (2, "X"),
        (3, "Y"),
        (4, "LS"),
        (5, "RS"),
        (6, "L"),
        (7, "R"),
        (8, "ZL"),
        (9, "ZR"),
        (10, "Plus"),
        (11, "Minus"),
        (12, "D-Left"),
        (13, "D-Up"),
        (14, "D-Right"),
        (15, "D-Down"),
        (16, "L-Left"),
        (17, "L-Up"),
        (18, "L-Right"),
        (19, "L-Down"),
        (20, "R-Left"),
        (21, "R-Up"),
        (22, "R-Right"),
        (23, "R-Down"),
        (24, "SL"),
        (25, "SR"),
    ]

    package static func buttonNames(for mask: UInt64) -> [String] {
        guard mask != 0 else { return [] }
        var names: [String] = []
        for entry in buttonLabels where (mask & (UInt64(1) << entry.bit)) != 0 {
            names.append(entry.label)
        }
        return names
    }

    package static func formattedCombo(for mask: UInt64) -> String? {
        let names = buttonNames(for: mask)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " + ")
    }
}

/// Static analyzer for Atmosphère cheat entries matching `dm/tools/cheat_bake.py` and `dm/host/hle_cheats.c`.
package enum CheatStaticAnalyzer {
    package struct InputEntry: Sendable {
        package var key: String
        package var isMaster: Bool
        package var isLabel: Bool
        package var isBroken: Bool
        package var words: [UInt32]

        package init(key: String, isMaster: Bool, isLabel: Bool, isBroken: Bool, words: [UInt32]) {
            self.key = key
            self.isMaster = isMaster
            self.isLabel = isLabel
            self.isBroken = isBroken
            self.words = words
        }
    }

    package struct Analysis: Equatable, Sendable {
        package var capability: CheatCapability
        package var keyMask: UInt64
        package var hasCodeWrite: Bool
        package var hasFixedHeapOffset: Bool

        package init(
            capability: CheatCapability = .dataReady,
            keyMask: UInt64 = 0,
            hasCodeWrite: Bool = false,
            hasFixedHeapOffset: Bool = false
        ) {
            self.capability = capability
            self.keyMask = keyMask
            self.hasCodeWrite = hasCodeWrite
            self.hasFixedHeapOffset = hasFixedHeapOffset
        }
    }

    /// Recognizes Zing single-word section markers: `20000000` (start) and `20000001` (end).
    package static func zingSectionMarker(words: [UInt32], isMaster: Bool, isBroken: Bool) -> Bool? {
        guard !isMaster, !isBroken, words.count == 1 else { return nil }
        if words[0] == 0x2000_0000 { return true }
        if words[0] == 0x2000_0001 { return false }
        return nil
    }

    /// Analyzes every entry in order (master dirty registers propagate to normal entries) and resolves its iOS capability and key mask.
    package static func analyze(
        entries: [InputEntry],
        rxEnd: UInt64?,
        trampolines: CheatTrampolineMetadata?,
        buildID: String?
    ) -> [Analysis] {
        let effectiveRxEnd = rxEnd ?? trampolines?.mainRxEnd ?? 0
        let trampolinesMatchBuild: Bool = {
            guard let trampolines else { return false }
            guard let expected = buildID?.uppercased(), !expected.isEmpty,
                  let tBuild = trampolines.buildID?.uppercased(), !tBuild.isEmpty else {
                return true
            }
            return expected == tBuild
        }()
        let activeTrampolines = trampolinesMatchBuild ? trampolines : nil

        var results = Array(repeating: Analysis(), count: entries.count)
        var masterDirty = Set<Int>()

        for pass in 0...1 {
            let wantMaster = (pass == 0)
            for idx in entries.indices {
                let entry = entries[idx]
                guard !entry.isLabel, !entry.isBroken, entry.isMaster == wantMaster else { continue }
                var dirty = wantMaster ? Set<Int>() : masterDirty
                var keyMask: UInt64 = 0
                var hasCodeWrite = false
                var hasFixedHeapOffset = false
                var failedDecode = false

                var pc = 0
                while pc < entry.words.count {
                    guard let decoded = decodeOpcode(words: entry.words, index: pc) else {
                        failedDecode = true
                        break
                    }
                    switch decoded.op {
                    case 0:
                        let isMain = decoded.mem == 0 || decoded.mem >= 5
                        let isHeap = decoded.mem == 1
                        if isMain {
                            if !dirty.contains(decoded.reg) {
                                if effectiveRxEnd > 0, decoded.rel < effectiveRxEnd {
                                    hasCodeWrite = true
                                }
                            } else {
                                hasCodeWrite = true
                            }
                        } else if isHeap, !dirty.contains(decoded.reg), decoded.rel > 0 {
                            hasFixedHeapOffset = true
                        }
                    case 8, 0xC4:
                        keyMask |= decoded.keyMask
                    case 3, 4, 5, 7, 9:
                        dirty.insert(decoded.reg)
                    case 6:
                        if decoded.inc { dirty.insert(decoded.reg) }
                    case 0xA:
                        if decoded.inc { dirty.insert(decoded.reg) }
                        if (decoded.operand == 3 || decoded.operand == 4 || decoded.operand == 5) && (decoded.mem == 0 || decoded.mem >= 5) {
                            hasCodeWrite = true
                        }
                    case 0xC1:
                        if decoded.cond != 1 && decoded.cond != 2 { dirty.insert(decoded.reg) }
                    case 0xC2:
                        if decoded.cond != 1 && decoded.cond != 2 {
                            for bit in 0..<16 where (decoded.regMask & (1 << bit)) != 0 {
                                dirty.insert(bit)
                            }
                        }
                    case 0xC3:
                        if decoded.extra < 0x80 { dirty.insert(decoded.reg) }
                    default:
                        break
                    }
                    pc += decoded.length
                }

                if wantMaster && !failedDecode {
                    masterDirty.formUnion(dirty)
                }

                let tRecord = activeTrampolines?.record(forKey: entry.key)
                if let tMask = tRecord?.keyMask, tMask != 0 {
                    keyMask |= tMask
                }

                let capability: CheatCapability
                if let activeTrampolines, activeTrampolines.isBaked(key: entry.key) {
                    capability = .codeBaked
                } else if tRecord?.kind == "unbaked_code" || hasCodeWrite {
                    capability = .codeNeedsBake
                } else if hasFixedHeapOffset {
                    capability = .fixedHeapWarning
                } else {
                    capability = .dataReady
                }

                results[idx] = Analysis(
                    capability: capability,
                    keyMask: keyMask,
                    hasCodeWrite: hasCodeWrite || (tRecord?.kind == "unbaked_code") || (activeTrampolines?.isBaked(key: entry.key) ?? false),
                    hasFixedHeapOffset: hasFixedHeapOffset
                )
            }
        }
        return results
    }

    private struct DecodedOp {
        var op: UInt32
        var length: Int
        var mem: Int = 0
        var reg: Int = 0
        var rel: UInt64 = 0
        var inc: Bool = false
        var operand: Int = 0
        var cond: Int = 0
        var regMask: Int = 0
        var extra: Int = 0
        var keyMask: UInt64 = 0
    }

    private static func widthOK(_ t: Int) -> Bool {
        t == 1 || t == 2 || t == 4 || t == 8
    }

    private static func decodeOpcode(words: [UInt32], index: Int) -> DecodedOp? {
        let remaining = words.count - index
        guard remaining > 0 else { return nil }
        let w = words[index]
        var op = w >> 28
        if op >= 0xC {
            op = (op << 4) | ((w >> 24) & 0xF)
        }
        if op >= 0xF0 {
            op = (op << 4) | ((w >> 20) & 0xF)
        }

        switch op {
        case 0:
            let t = Int((w >> 24) & 0xF)
            let len = t == 8 ? 4 : 3
            guard widthOK(t), remaining >= len else { return nil }
            let rel = (UInt64(w & 0xFF) << 32) | UInt64(words[index + 1])
            return DecodedOp(op: op, length: len, mem: Int((w >> 20) & 0xF), reg: Int((w >> 16) & 0xF), rel: rel)
        case 1:
            let t = Int((w >> 24) & 0xF)
            let c = Int((w >> 16) & 0xF)
            let len = t == 8 ? 4 : 3
            guard widthOK(t), c >= 1, c <= 6, remaining >= len else { return nil }
            return DecodedOp(op: op, length: len)
        case 2:
            return DecodedOp(op: op, length: 1)
        case 3:
            let isEnd = ((w >> 24) & 0xF) != 0
            let len = isEnd ? 1 : 2
            guard remaining >= len else { return nil }
            return DecodedOp(op: op, length: len, reg: Int((w >> 16) & 0xF))
        case 4:
            guard remaining >= 3 else { return nil }
            return DecodedOp(op: op, length: 3, reg: Int((w >> 16) & 0xF))
        case 5:
            let t = Int((w >> 24) & 0xF)
            let flags = Int((w >> 12) & 0xF)
            guard widthOK(t), flags <= 3, remaining >= 2 else { return nil }
            return DecodedOp(op: op, length: 2, reg: Int((w >> 16) & 0xF))
        case 6:
            let t = Int((w >> 24) & 0xF)
            guard widthOK(t), remaining >= 3 else { return nil }
            return DecodedOp(op: op, length: 3, reg: Int((w >> 16) & 0xF), inc: ((w >> 12) & 0xF) != 0)
        case 7:
            let t = Int((w >> 24) & 0xF)
            let c = Int((w >> 12) & 0xF)
            guard widthOK(t), c <= 4, remaining >= 2 else { return nil }
            return DecodedOp(op: op, length: 2, reg: Int((w >> 16) & 0xF))
        case 8:
            return DecodedOp(op: op, length: 1, keyMask: UInt64(w & 0x0FFF_FFFF))
        case 9:
            let t = Int((w >> 24) & 0xF)
            guard widthOK(t) else { return nil }
            let imm = ((w >> 8) & 0xF) != 0
            let len = imm ? (t == 8 ? 3 : 2) : 1
            guard remaining >= len else { return nil }
            return DecodedOp(op: op, length: len, reg: Int((w >> 16) & 0xF))
        case 0xA:
            let t = Int((w >> 24) & 0xF)
            let o = Int((w >> 8) & 0xF)
            guard widthOK(t), o <= 5 else { return nil }
            let len = (o == 2 || o == 4 || o == 5) ? 2 : 1
            guard remaining >= len else { return nil }
            return DecodedOp(
                op: op,
                length: len,
                mem: Int((w >> 4) & 0xF),
                reg: Int((w >> 16) & 0xF),
                inc: ((w >> 12) & 0xF) != 0,
                operand: o
            )
        case 0xC0:
            let t = Int((w >> 20) & 0xF)
            let c = Int((w >> 16) & 0xF)
            let o = Int((w >> 8) & 0xF)
            guard widthOK(t), c >= 1, c <= 6, o <= 5 else { return nil }
            let len = (o == 0 || o == 2) ? 2 : (o == 4 ? (t == 8 ? 3 : 2) : 1)
            guard remaining >= len else { return nil }
            return DecodedOp(op: op, length: len)
        case 0xC1:
            return DecodedOp(op: op, length: 1, reg: Int((w >> 16) & 0xF), cond: Int((w >> 4) & 0xF))
        case 0xC2:
            return DecodedOp(op: op, length: 1, cond: Int((w >> 20) & 0xF), regMask: Int(w & 0xFFFF))
        case 0xC3:
            return DecodedOp(op: op, length: 1, reg: Int(w & 0xF), extra: Int((w >> 4) & 0xFF))
        case 0xC4:
            guard remaining >= 3 else { return nil }
            let km = (UInt64(words[index + 1]) << 32) | UInt64(words[index + 2])
            return DecodedOp(op: op, length: 3, keyMask: km)
        default:
            return nil
        }
    }
}
