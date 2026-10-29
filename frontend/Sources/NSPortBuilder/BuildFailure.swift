import Foundation

/// The early stops of the NSP script that the launcher can turn into a next step. The script prints a
/// `[RED]` line and exits 1 for each (a `BuildError`), and the launcher used to show only the last line of
/// the log, cut to 200 characters. The classifier reads the whole log tail, because for a damaged NSP the
/// last line is only "nx_extract exit code 3" and the message is a few lines above it.
enum BuildFailureKind: String, CaseIterable {
    case rosetta, translator, iosSDK, cltSelected, otherMetal, shaderRegression, damagedNSP, a32Program, unknown

    /// The script's override for this stop, offered as "Build anyway". Only these three have one that the launcher
    /// may offer: the others cannot be built around (a 32-bit program, a missing SDK).
    var overrideFlag: String? {
        switch self {
        case .otherMetal: return "--allow-other-metal"
        case .shaderRegression: return "--allow-shader-regressions"
        case .damagedNSP: return "--allow-damaged"
        default: return nil
        }
    }

    /// L10n keys: what happened, and the next step.
    var whatKey: String { "fail.\(rawValue).what" }
    var nextKey: String { "fail.\(rawValue).next" }
}

struct BuildFailure: Equatable {
    var kind: BuildFailureKind
    var gameName: String?   // a32Program: the game, when the message names it
}

enum BuildFailureClassifier {
    /// One row per message of the script. The pattern is a stable part of the text in scripts/build_ipa_from_nsp.py,
    /// dm/gfx/tools/own_compilers.py or dm/tools/nx_extract/Program.cs (regular expressions, searched in the log).
    /// Frontend/Tests/Fixtures/build_failures.json holds the real message for every row, and a test checks that each
    /// fragment is still in the vendored script, so a sync that rewords a message fails there instead of turning a
    /// hint into the raw last line. The Qt front end has the same table (nspb_qt/build_failure.py, compared by a test).
    static let table: [(id: String, kind: BuildFailureKind, pattern: String)] = [
        ("rosetta.intel", .rosetta, "is an Intel one running under Rosetta"),
        ("translator.run", .translator, "the shader translator does not run"),
        ("translator.start", .translator, "the shader translator does not start"),
        ("ios.sdk", .iosSDK, "the iOS SDK is not installed"),
        ("clt.selected", .cltSelected, "the selected developer folder is the Command Line Tools"),
        ("metal.other", .otherMetal, "Metal compiler is not the one the shaders were tested with"),
        ("shaders.regression", .shaderRegression, "a change to the translation chain broke them"),
        ("nsp.damaged", .damagedNSP, "files fail the NCA's hash check"),
        ("arm32.program", .a32Program, "is a 32-bit ARM program"),
    ]

    /// `unknown` when no row matches: the caller then keeps showing the last line of the log.
    static func classify(_ log: String) -> BuildFailure {
        for row in table where log.range(of: row.pattern, options: .regularExpression) != nil {
            return BuildFailure(kind: row.kind, gameName: row.kind == .a32Program ? gameName(in: log) : nil)
        }
        return BuildFailure(kind: .unknown, gameName: nil)
    }

    /// "<name> (<title ID>) is a 32-bit ARM program": the name is "?" when the extraction has none.
    static func gameName(in log: String) -> String? {
        guard let r = log.range(of: #"(?m)^(?:\[RED\] )?.+? \([0-9A-Fa-f]{16}\) is a 32-bit ARM program"#, options: .regularExpression) else { return nil }
        var line = String(log[r])
        if line.hasPrefix("[RED] ") { line.removeFirst(6) }
        guard let paren = line.range(of: " (", options: .backwards, range: nil, locale: nil) else { return nil }
        let name = String(line[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "?" ? nil : name
    }

    /// The build arguments with the one-off override added: exactly one `--allow-*`, or none.
    static func arguments(_ args: [String], adding flag: String?) -> [String] {
        let rest = args.filter { !$0.hasPrefix("--allow-") }
        guard let flag, flag.hasPrefix("--allow-") else { return rest }
        return rest + [flag]
    }
}

/// The Metal compiler the shaders were tested with (dm/gfx/tools/dmsh_chain.lock) against this Mac's. NVN games stop at the
/// start of the shader steps with another compiler (own_compilers.py --check-metal), so the dependency panel says so beforehand.
/// The comparison is the script's: the first line of `xcrun -sdk <sdk> metal --version`, and a compiler that is not there is
/// not a mismatch (its own row reports a missing one).
enum MetalPin {
    struct Mismatch: Equatable { var sdk: String; var now: String; var pinned: String }

    static let lockPath = "dm/gfx/tools/dmsh_chain.lock"

    /// `metal_macosx` / `metal_iphoneos` lines of the lock: tab separated, `#` for comments.
    static func pins(lock: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in lock.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    /// `now`: the compilers found, by SDK name (macosx, iphoneos), nil for one that did not answer.
    /// An iOS compiler is compared only when `iOS` (the build is for an iPhone).
    static func mismatches(lock: String, now: [String: String?], iOS: Bool) -> [Mismatch] {
        let pinned = pins(lock: lock)
        var out: [Mismatch] = []
        for sdk in iOS ? ["macosx", "iphoneos"] : ["macosx"] {
            guard let want = pinned["metal_" + sdk], let found = now[sdk] ?? nil, !found.isEmpty, found != want else { continue }
            out.append(Mismatch(sdk: sdk, now: found, pinned: want))
        }
        return out
    }
}
