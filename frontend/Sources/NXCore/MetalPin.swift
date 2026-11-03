import Foundation

/// The Metal compiler the shaders were tested with (dm/gfx/tools/dmsh_chain.lock) against this Mac's. NVN games stop at the
/// start of the shader steps with another compiler of the lock's generation or an older one (own_compilers.py --check-metal), so
/// the dependency panel says so beforehand; a newer compiler of the same generation builds with a note, like the script's gate.
/// The comparison is the script's: the first line of `xcrun -sdk <sdk> metal --version`, and a compiler that is not there is
/// not a mismatch (its own row reports a missing one).
package enum MetalPin {
    package struct Mismatch: Equatable { package var sdk: String; package var now: String; package var pinned: String }

    package static let lockPath = "dm/gfx/tools/dmsh_chain.lock"

    /// `metal_macosx` / `metal_iphoneos` lines of the lock: tab separated, `#` for comments.
    package static func pins(lock: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in lock.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    /// `now`: the compilers found, by SDK name (macosx, iphoneos), nil for one that did not answer.
    /// An iOS compiler is compared only when `iOS` (the build is for an iPhone).
    /// A newer compiler of the recorded generation is not a mismatch: Xcode's auto-update bumps it
    /// and a player cannot hold Xcode back — the engine's gate builds with a note (own_compilers.py, #242).
    package static func mismatches(lock: String, now: [String: String?], iOS: Bool) -> [Mismatch] {
        let pinned = pins(lock: lock)
        var out: [Mismatch] = []
        for sdk in iOS ? ["macosx", "iphoneos"] : ["macosx"] {
            guard let want = pinned["metal_" + sdk], let found = now[sdk] ?? nil, !found.isEmpty, found != want, !buildsOn(tested: want, found: found) else { continue }
            out.append(Mismatch(sdk: sdk, now: found, pinned: want))
        }
        return out
    }

    /// `Apple metal version 32023.921 (metalfe-32023.921.6)` → (32023, 921, 6); nil for another shape.
    package static func version(_ s: String) -> (Int, Int, Int)? {
        let text = s.trimmingCharacters(in: .whitespaces)
        let pattern = "^Apple metal version (\\d+)\\.(\\d+) \\(metalfe-\\d+\\.\\d+\\.(\\d+)\\)$"
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges == 4 else { return nil }
        let g = { (i: Int) in Int((text as NSString).substring(with: m.range(at: i))) }
        return g(1) != nil && g(2) != nil && g(3) != nil ? (g(1)!, g(2)!, g(3)!) : nil
    }

    /// Same leading version and strictly newer: the tested Xcode's compiler against the one an auto-update brought.
    package static func buildsOn(tested: String, found: String) -> Bool {
        guard let a = version(tested), let b = version(found) else { return false }
        return a.0 == b.0 && b > a
    }
}
