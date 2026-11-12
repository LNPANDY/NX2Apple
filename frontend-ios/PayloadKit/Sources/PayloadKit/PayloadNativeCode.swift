import Foundation
import PayloadValidation

public enum PayloadNativeCode {
    static func word(_ data: Data, _ offset: Int, big: Bool = false) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 4)]
        return big ? bytes.reduce(0) { ($0 << 8) | UInt32($1) }
            : bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// The payload ABI supports thin arm64 dylibs/bundles. GPU Mach-O resources
    /// have a different CPU type and must never be sent to the native signer.
    public static func isLibrary(_ url: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let head = try input.read(upToCount: 32) ?? Data()
        guard word(head, 0) == 0xfeedfacf, word(head, 4) == 0x0100000c else { return false }
        guard [UInt32(6), 8].contains(word(head, 12) ?? 0) else { throw PayloadError.invalid("native image is not a library") }
        return true
    }

    /// Diagnostic/team preflight only. Kernel signature validation remains
    /// mandatory: CodeDirectory contents alone do not authenticate a file.
    public static func teamID(_ url: URL) throws -> String? {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 32) ?? Data()
        guard word(header, 0) == 0xfeedfacf, let ncmds = word(header, 16),
              let commandBytes = word(header, 20), commandBytes <= 16 << 20, ncmds <= commandBytes / 8 else { return nil }
        let commands = try input.read(upToCount: Int(commandBytes)) ?? Data()
        var offset = 0
        for _ in 0..<ncmds {
            guard let cmd = word(commands, offset), let bytes = word(commands, offset + 4),
                  bytes >= 8, Int(bytes) <= commands.count - offset else { return nil }
            if cmd == 0x1d, bytes >= 16, let start = word(commands, offset + 8), let count = word(commands, offset + 12), count <= 64 << 20 {
                try input.seek(toOffset: UInt64(start))
                let blob = try input.read(upToCount: Int(count)) ?? Data()
                guard word(blob, 0, big: true) == 0xfade0cc0, let length = word(blob, 4, big: true), length >= 12,
                      length <= blob.count, let entries = word(blob, 8, big: true), entries <= 4096, entries <= (length - 12) / 8 else { return nil }
                for index in 0..<Int(entries) {
                    guard let slot = word(blob, 12 + index * 8, big: true), let pos = word(blob, 16 + index * 8, big: true) else { return nil }
                    guard slot == 0 || (0x1000...0x1005).contains(slot) else { continue }
                    let base = Int(pos)
                    guard word(blob, base, big: true) == 0xfade0c02, let size = word(blob, base + 4, big: true),
                          size >= 52, size <= length, base >= 12 + Int(entries) * 8, base <= Int(length - size),
                          let version = word(blob, base + 8, big: true), version >= 0x20200,
                          let team = word(blob, base + 48, big: true), team >= 52, team < size else { continue }
                    let tail = blob[(base + Int(team))..<(base + Int(size))]
                    guard let end = tail.firstIndex(of: 0), tail.distance(from: tail.startIndex, to: end) <= 128 else { return nil }
                    return String(data: tail[..<end], encoding: .utf8)
                }
            }
            offset += Int(bytes)
        }
        return nil
    }

    public static func validate(_ url: URL) throws {
        var message = [CChar](repeating: 0, count: 1024)
        let result = url.path.withCString { path in nx_payload_validate(path, &message, message.count) }
        guard result == 0 else { throw PayloadError.signature(String(decoding: message.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
    }

    public static func validateFramework(_ manifest: PayloadManifest, directory: URL,
                                         validate: @Sendable (URL) throws -> Void = PayloadNativeCode.validate) throws {
        let framework = directory.appendingPathComponent(manifest.framework)
        let main = framework.appendingPathComponent(manifest.executable)
        guard try isLibrary(main) else { throw PayloadError.invalid("main framework architecture") }
        let infoURL = framework.appendingPathComponent("Info.plist")
        let gameURL = framework.appendingPathComponent("game.manifest.json")
        guard try PayloadArchive.size(infoURL) <= 1 << 20, try PayloadArchive.size(gameURL) <= 1 << 20 else {
            throw PayloadError.invalid("framework metadata too large")
        }
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleExecutable"] as? String == manifest.executable else { throw PayloadError.invalid("framework Info.plist") }
        let game = try JSONSerialization.jsonObject(with: Data(contentsOf: gameURL)) as? [String: Any]
        guard let game, game["schema"] as? Int == 1, game["loader"] as? String == "FH",
              game["title_id"] as? String == manifest.titleID, game["framework"] as? String == manifest.framework,
              game["framework_executable"] as? String == manifest.executable,
              game["display_version"] as? String == manifest.displayVersion, game["min_os"] as? String == manifest.minOS,
              let modules = game["modules"] as? [String], !modules.isEmpty,
              modules.allSatisfy(PayloadManifest.safePath) else { throw PayloadError.invalid("game manifest") }
        for key in ["profile", "shader_map", "launcher"] {
            guard let path = game[key] as? String, PayloadManifest.safePath(path),
                  manifest.files.contains(where: { $0.path == manifest.framework + "/" + path }) else {
                throw PayloadError.invalid("game resource path")
            }
            if key == "launcher", try PayloadArchive.size(framework.appendingPathComponent(path)) > 4 << 20 {
                throw PayloadError.invalid("launcher metadata too large")
            }
        }
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.path)
            guard try isLibrary(url) else { continue }
            guard try teamID(url) == manifest.teamID else { throw PayloadError.signature("signing team mismatch") }
            try validate(url)
        }
    }
}
