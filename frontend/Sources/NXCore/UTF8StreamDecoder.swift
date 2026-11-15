import Foundation

/// Decodes an arbitrary byte stream as UTF-8 without dropping chunks when a multi-byte scalar straddles a pipe read boundary.
///
/// Up to three trailing bytes that form a valid, incomplete UTF-8 sequence prefix are held back for the next chunk. Every
/// complete prefix before them is decoded with replacement characters (`\u{FFFD}`) for malformed bytes rather than failing the
/// whole chunk. Call `finish()` at end of stream to flush any leftover incomplete prefix as replacement characters.
package struct UTF8StreamDecoder: Sendable {
    private var pending = Data()

    package init() {}

    package mutating func decode(_ chunk: Data) -> String {
        guard !chunk.isEmpty else { return "" }
        let combined: Data
        if pending.isEmpty {
            combined = chunk
        } else {
            var merged = pending
            pending.removeAll(keepingCapacity: true)
            merged.append(chunk)
            combined = merged
        }
        let hold = Self.incompleteSuffixCount(combined)
        if hold == 0 {
            return String(decoding: combined, as: UTF8.self)
        }
        if hold == combined.count {
            pending = Data(combined)
            return ""
        }
        let split = combined.index(combined.endIndex, offsetBy: -hold)
        pending = Data(combined[split...])
        return String(decoding: combined[..<split], as: UTF8.self)
    }

    package mutating func finish() -> String {
        guard !pending.isEmpty else { return "" }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// Number of trailing bytes (`0...3`) that begin a valid RFC 3629 multi-byte UTF-8 sequence not yet completed.
    static func incompleteSuffixCount(_ data: Data) -> Int {
        let count = data.count
        guard count > 0 else { return 0 }
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            var continuations = 0
            while continuations < 3, continuations < count, (base[count - 1 - continuations] & 0xC0) == 0x80 {
                continuations += 1
            }
            let leadIndex = count - 1 - continuations
            guard leadIndex >= 0 else { return 0 }
            let lead = base[leadIndex]
            let expected: Int
            switch lead {
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            default: return 0
            }
            let remaining = continuations + 1
            guard remaining < expected else { return 0 }
            if remaining >= 2 {
                let second = base[leadIndex + 1]
                if lead == 0xE0, second < 0xA0 { return 0 }
                if lead == 0xED, second > 0x9F { return 0 }
                if lead == 0xF0, second < 0x90 { return 0 }
                if lead == 0xF4, second > 0x8F { return 0 }
            }
            return remaining
        }
    }

    /// Lock-protected wrapper for callbacks invoked across pipe and termination queues.
    package final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var decoder = UTF8StreamDecoder()

        package init() {}

        package func decode(_ chunk: Data) -> String {
            lock.lock(); defer { lock.unlock() }
            return decoder.decode(chunk)
        }

        package func finish() -> String {
            lock.lock(); defer { lock.unlock() }
            return decoder.finish()
        }
    }
}
