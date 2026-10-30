import Foundation

/// File conversion with the bundled nsz (frontend/bundled-python/requirements.txt): a compressed dump
/// (.nsz/.xcz) decompresses to .nsp/.xci, and the other way around. LumaNX ships a whole workspace for
/// this; ours is the one thing players actually asked for, running the same tool the build runs.
enum FileConvert {
    enum Kind: String, CaseIterable {
        case decompress
        case compress

        var flag: String { self == .decompress ? "-D" : "-C" }
    }

    /// What a file can become. A compressed dump decompresses; a plain package compresses.
    nonisolated static func kind(for path: String) -> Kind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "nsz", "xcz": return .decompress
        case "nsp", "xci": return .compress
        default: return nil
        }
    }

    /// The command the build itself runs nsz with (`python -m nsz`), against the interpreter the
    /// launcher builds with — so the bundled nsz is used and nothing new is installed.
    nonisolated static func command(python: String, kind: Kind, path: String) -> [String] {
        [python, "-m", "nsz", kind.flag, path]
    }

    /// The output file nsz writes beside the input: the same stem, the other extension.
    nonisolated static func output(for path: String, kind: Kind) -> String {
        let base = (path as NSString).deletingPathExtension
        return kind == .decompress
            ? base + "." + ((path as NSString).pathExtension.lowercased() == "nsz" ? "nsp" : "xci")
            : base + ".nsz"
    }

    /// The files of a selection this tool can act on, in order, and what it would make of them.
    nonisolated static func plan(for paths: [String]) -> [(path: String, kind: Kind, output: String)] {
        paths.compactMap { path in
            guard let kind = kind(for: path) else { return nil }
            return (path, kind, output(for: path, kind: kind))
        }
    }
}
