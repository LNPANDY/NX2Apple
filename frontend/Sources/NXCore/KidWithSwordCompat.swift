import Foundation

/// macOS launcher compatibility guard for external `Kid with Sword` (`cheemu21/kid-with-sword-remake`) trees.
///
/// Upstream commit `1f1c2ec` (included in `94d1895`) added an iOS-only `MicTesterView` sheet and
/// "Test Microphone" section to `dm/ios/Sources/LauncherHome.swift`, which `dm/mac/pack_app.py` compiles
/// into the Mac app without `dm/ios/Sources/MicTester.swift` (which depends on iOS-only `AVAudioSession`).
/// Wrapping those blocks in `#if os(iOS)` lets macOS `pack_app.py` compile cleanly while leaving iOS unchanged.
package enum KidWithSwordCompat {
    package static let launcherHomeRelativePath = "dm/ios/Sources/LauncherHome.swift"
    package static let macPackScriptRelativePath = "dm/mac/pack_app.py"

    /// Ensures `dm/ios/Sources/LauncherHome.swift` guards iOS-only `MicTesterView` references when
    /// `dm/mac/pack_app.py` compiles `LauncherHome.swift` without `MicTester.swift`.
    /// Returns `true` when `LauncherHome.swift` was updated, or `false` when already compatible or inapplicable.
    @discardableResult
    package static func ensureMacPackCompatibility(
        in treePath: String,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !treePath.isEmpty else { return false }
        let rootURL = URL(fileURLWithPath: treePath, isDirectory: true).standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        let packURL = rootURL.appendingPathComponent(macPackScriptRelativePath)
        let homeURL = rootURL.appendingPathComponent(launcherHomeRelativePath)
        guard isContainedRegularFile(packURL, within: rootPrefix, fileManager: fm),
              isContainedRegularFile(homeURL, within: rootPrefix, fileManager: fm) else {
            return false
        }
        guard let packSource = try? String(contentsOf: packURL, encoding: .utf8),
              packSource.contains("LauncherHome.swift"),
              !packSource.contains("MicTester.swift") else {
            return false
        }
        guard let original = try? String(contentsOf: homeURL, encoding: .utf8),
              let patched = patchLauncherHomeSource(original),
              patched != original else {
            return false
        }
        do {
            try Data(patched.utf8).write(to: homeURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Guards unguarded `MicTesterView` sheet modifiers and matching "Test Microphone" button blocks
    /// with `#if os(iOS)` ... `#endif`. Returns `nil` when no unguarded `MicTesterView(` reference exists.
    package static func patchLauncherHomeSource(_ source: String) -> String? {
        guard source.contains("MicTesterView(") else { return nil }

        let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        let lines = source.components(separatedBy: lineEnding)
        var ifStack: [Bool] = []
        var rangesToGuard: [ClosedRange<Int>] = []
        var hasUnguardedMicTesterView = false

        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if updateDirectiveStack(&ifStack, trimmedLine: trimmed) {
                i += 1
                continue
            }
            if ifStack.contains(true) {
                i += 1
                continue
            }

            let code = stripLineComment(lines[i])
            if trimmed.hasPrefix("if "),
               let end = blockEndLine(lines: lines, start: i) {
                let blockText = lines[i...end].joined(separator: "\n")
                if blockText.contains("\"Test Microphone\"") && blockText.contains("testingMic") {
                    rangesToGuard.append(i...end)
                    i = end + 1
                    continue
                }
            }

            if code.contains(".sheet("),
               let end = blockEndLine(lines: lines, start: i) {
                let blockText = lines[i...end].joined(separator: "\n")
                if blockText.contains("MicTesterView(") {
                    rangesToGuard.append(i...end)
                    hasUnguardedMicTesterView = true
                    i = end + 1
                    continue
                }
            } else if code.contains("MicTesterView(") {
                let end = blockEndLine(lines: lines, start: i) ?? i
                rangesToGuard.append(i...end)
                hasUnguardedMicTesterView = true
                i = end + 1
                continue
            }

            i += 1
        }

        guard hasUnguardedMicTesterView, !rangesToGuard.isEmpty else { return nil }

        var result: [String] = []
        result.reserveCapacity(lines.count + rangesToGuard.count * 2)
        var rangeIndex = 0
        var lineIndex = 0
        while lineIndex < lines.count {
            if rangeIndex < rangesToGuard.count, rangesToGuard[rangeIndex].lowerBound == lineIndex {
                let range = rangesToGuard[rangeIndex]
                let indent = leadingWhitespace(of: lines[range.lowerBound])
                result.append(indent + "#if os(iOS)")
                result.append(contentsOf: lines[range])
                result.append(indent + "#endif")
                lineIndex = range.upperBound + 1
                rangeIndex += 1
            } else {
                result.append(lines[lineIndex])
                lineIndex += 1
            }
        }
        return result.joined(separator: lineEnding)
    }

    private static func isContainedRegularFile(_ url: URL, within rootPrefix: String, fileManager fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        let resolved = url.resolvingSymlinksInPath().path
        return resolved.hasPrefix(rootPrefix)
    }

    private static func updateDirectiveStack(_ stack: inout [Bool], trimmedLine: String) -> Bool {
        if trimmedLine.hasPrefix("#if ") {
            let cond = String(trimmedLine.dropFirst(4))
            stack.append(isIOSCondition(cond))
            return true
        }
        if trimmedLine.hasPrefix("#elseif ") {
            let cond = String(trimmedLine.dropFirst(8))
            if !stack.isEmpty {
                stack[stack.count - 1] = isIOSCondition(cond)
            }
            return true
        }
        if trimmedLine == "#else" || trimmedLine.hasPrefix("#else ") || trimmedLine.hasPrefix("#else//") {
            if !stack.isEmpty {
                stack[stack.count - 1] = false
            }
            return true
        }
        if trimmedLine == "#endif" || trimmedLine.hasPrefix("#endif ") || trimmedLine.hasPrefix("#endif//") {
            if !stack.isEmpty {
                stack.removeLast()
            }
            return true
        }
        return false
    }

    private static func isIOSCondition(_ condition: String) -> Bool {
        let code = stripLineComment(condition)
        guard code.contains("os(iOS)") else { return false }
        return !code.contains("!os(iOS)")
    }

    /// Scans from `start` until the first `{` opened on `start` (or a continuation line) returns to depth 0.
    private static func blockEndLine(lines: [String], start: Int) -> Int? {
        var depth = 0
        var sawOpeningBrace = false
        var inBlockComment = false
        for idx in start..<lines.count {
            let chars = Array(lines[idx])
            var j = 0
            var inString = false
            while j < chars.count {
                let c = chars[j]
                let next: Character? = (j + 1 < chars.count) ? chars[j + 1] : nil
                if inBlockComment {
                    if c == "*" && next == "/" {
                        inBlockComment = false
                        j += 2
                        continue
                    }
                    j += 1
                    continue
                }
                if inString {
                    if c == "\\" && next != nil {
                        j += 2
                        continue
                    }
                    if c == "\"" {
                        inString = false
                    }
                    j += 1
                    continue
                }
                if c == "/" && next == "/" {
                    break
                }
                if c == "/" && next == "*" {
                    inBlockComment = true
                    j += 2
                    continue
                }
                if c == "\"" {
                    inString = true
                    j += 1
                    continue
                }
                if c == "{" {
                    depth += 1
                    sawOpeningBrace = true
                } else if c == "}" {
                    depth -= 1
                }
                j += 1
            }
            if sawOpeningBrace && depth <= 0 {
                return idx
            }
            if !sawOpeningBrace && idx - start >= 3 {
                return nil
            }
        }
        return nil
    }

    private static func stripLineComment(_ line: String) -> String {
        let chars = Array(line)
        var inString = false
        var j = 0
        while j < chars.count {
            let c = chars[j]
            let next: Character? = (j + 1 < chars.count) ? chars[j + 1] : nil
            if inString {
                if c == "\\" && next != nil {
                    j += 2
                    continue
                }
                if c == "\"" {
                    inString = false
                }
                j += 1
                continue
            }
            if c == "\"" {
                inString = true
                j += 1
                continue
            }
            if c == "/" && next == "/" {
                return String(chars[0..<j])
            }
            j += 1
        }
        return line
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }
}
