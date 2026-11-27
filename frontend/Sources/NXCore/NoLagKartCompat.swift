import Foundation

/// macOS launcher compatibility guard for external `No Lag Kart` (`kingbumi31/no-lag-kart`) trees.
///
/// Upstream `dm/host/Makefile` passes `-fprofile-instr-use=$(abspath ../../mkw/pgo/dmhost.profdata)`
/// to `clang` without quotes. When NX2Apple installs the engine under
/// `~/Library/Application Support/NX2Apple/upstreams/nolagkart`, the space in `Application Support`
/// splits the flag and causes `clang` to fail reading the profile.
/// Wrapping the unquoted expansion in double quotes keeps it as a single argument.
package enum NoLagKartCompat {
    package static let hostMakefileRelativePath = "dm/host/Makefile"

    /// Ensures `dm/host/Makefile` quotes unquoted `-fprofile-instr-use=$(abspath ...)` (and similar
    /// unquoted `dmhost.profdata` variable expansions) so paths containing spaces build cleanly.
    /// Returns `true` when `dm/host/Makefile` was updated, or `false` when already compatible or inapplicable.
    @discardableResult
    package static func ensureMacMakefileCompatibility(
        in treePath: String,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !treePath.isEmpty else { return false }
        let rootURL = URL(fileURLWithPath: treePath, isDirectory: true).standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        let makefileURL = rootURL.appendingPathComponent(hostMakefileRelativePath)
        guard isContainedRegularFile(makefileURL, within: rootPrefix, fileManager: fm) else {
            return false
        }
        guard let original = try? String(contentsOf: makefileURL, encoding: .utf8),
              let patched = patchHostMakefileSource(original),
              patched != original else {
            return false
        }
        do {
            try Data(patched.utf8).write(to: makefileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Quotes unquoted `-fprofile-instr-use=$(abspath ...)` and similar unquoted `dmhost.profdata`
    /// expansions in `dm/host/Makefile`. Returns `nil` when no unquoted expansion needs patching.
    package static func patchHostMakefileSource(_ source: String) -> String? {
        guard source.contains("-fprofile-instr-use=") else { return nil }

        let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        let lines = source.components(separatedBy: lineEnding)
        var changed = false
        var patchedLines: [String] = []
        patchedLines.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || !line.contains("-fprofile-instr-use=") {
                patchedLines.append(line)
                continue
            }
            if let updated = patchMakefileLine(line) {
                patchedLines.append(updated)
                changed = true
            } else {
                patchedLines.append(line)
            }
        }

        guard changed else { return nil }
        return patchedLines.joined(separator: lineEnding)
    }

    private static func patchMakefileLine(_ line: String) -> String? {
        let flag = "-fprofile-instr-use="
        var result = ""
        var cursor = line.startIndex
        var changed = false

        while cursor < line.endIndex,
              let range = line.range(of: flag, range: cursor..<line.endIndex) {
            result.append(contentsOf: line[cursor..<range.upperBound])

            let valueStart = range.upperBound
            if isAlreadyQuoted(in: line, flagStart: range.lowerBound, valueStart: valueStart) {
                cursor = valueStart
                continue
            }

            let valueEnd = scanUnquotedMakefileValueEnd(in: line, from: valueStart)
            let value = String(line[valueStart..<valueEnd])
            if shouldQuoteProfileValue(value) {
                result.append("\"")
                result.append(value)
                result.append("\"")
                changed = true
            } else {
                result.append(value)
            }
            cursor = valueEnd
        }

        guard changed else { return nil }
        result.append(contentsOf: line[cursor..<line.endIndex])
        return result
    }

    private static func isAlreadyQuoted(
        in line: String,
        flagStart: String.Index,
        valueStart: String.Index
    ) -> Bool {
        if valueStart < line.endIndex {
            let first = line[valueStart]
            if first == "\"" || first == "'" {
                return true
            }
        }
        if flagStart > line.startIndex {
            let prev = line[line.index(before: flagStart)]
            if prev == "\"" || prev == "'" {
                return true
            }
        }
        return false
    }

    /// Scans a Makefile flag value from `from` until top-level whitespace or `#` comment,
    /// keeping `$(...)` and `${...}` expansions (which may contain internal spaces like `$(abspath ...)`).
    private static func scanUnquotedMakefileValueEnd(in line: String, from start: String.Index) -> String.Index {
        var idx = start
        var parenDepth = 0
        var braceDepth = 0

        while idx < line.endIndex {
            let ch = line[idx]
            let nextIdx = line.index(after: idx)
            if ch == "$" && nextIdx < line.endIndex {
                let nextCh = line[nextIdx]
                if nextCh == "(" {
                    parenDepth += 1
                    idx = line.index(after: nextIdx)
                    continue
                } else if nextCh == "{" {
                    braceDepth += 1
                    idx = line.index(after: nextIdx)
                    continue
                }
            }

            if parenDepth > 0 {
                if ch == "(" {
                    parenDepth += 1
                } else if ch == ")" {
                    parenDepth -= 1
                }
                idx = nextIdx
                continue
            }

            if braceDepth > 0 {
                if ch == "{" {
                    braceDepth += 1
                } else if ch == "}" {
                    braceDepth -= 1
                }
                idx = nextIdx
                continue
            }

            if ch == " " || ch == "\t" || ch == "#" {
                break
            }
            idx = nextIdx
        }

        return idx
    }

    private static func shouldQuoteProfileValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.contains("$(abspath ") || value.contains("${abspath ")
            || value.contains("$(abspath\t") || value.contains("${abspath\t") {
            return true
        }
        if value.contains("dmhost.profdata") && (value.contains("$(") || value.contains("${")) {
            return true
        }
        return false
    }

    private static func isContainedRegularFile(
        _ url: URL,
        within rootPrefix: String,
        fileManager fm: FileManager
    ) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        let resolved = url.resolvingSymlinksInPath().path
        return resolved.hasPrefix(rootPrefix)
    }
}
