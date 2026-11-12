import Foundation
import ShellUI

/// Reads `ExpirationDate` from the app's `embedded.mobileprovision` so players using a 7-day free Apple ID signature
/// get a calm heads-up within 48 hours of expiry before iOS stops launching the app.
public enum ProvisioningProfile {
    /// Upper bound on profile file size (4 MiB) so a damaged or unexpected file never allocates unbounded memory.
    public static let maxProfileBytes = 4 * 1024 * 1024
    /// Warn when 48 hours or less remain on the provisioning profile.
    public static let warningWindow: TimeInterval = 48 * 3600

    /// Reads `ExpirationDate` from `Bundle.main`'s `embedded.mobileprovision`, or nil when absent or unreadable.
    public static func bundledExpiration(bundle: Bundle = .main, fileManager fm: FileManager = .default) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return expiration(at: url, fileManager: fm)
    }

    /// Reads `TeamIdentifier` (10-character Apple developer team ID) from `Bundle.main`'s `embedded.mobileprovision`, or nil when absent.
    public static func bundledTeamIdentifier(bundle: Bundle = .main, fileManager fm: FileManager = .default) -> String? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return teamIdentifier(at: url, fileManager: fm)
    }

    /// Reads `TeamIdentifier` from a `.mobileprovision` file at `url`, returning nil safely on missing, oversize or damaged files.
    public static func teamIdentifier(at url: URL, fileManager fm: FileManager = .default) -> String? {
        guard let data = profileData(at: url, fileManager: fm) else { return nil }
        return teamIdentifier(fromProfile: data)
    }

    /// Extracts the signing team identifier from raw CMS-signed `.mobileprovision` bytes or a plain XML/binary property list.
    public static func teamIdentifier(fromProfile data: Data) -> String? {
        guard let dict = plist(fromProfile: data) else { return nil }
        if let teams = dict["TeamIdentifier"] as? [String], let first = teams.first(where: { !$0.isEmpty }) {
            return first
        }
        if let entitlements = dict["Entitlements"] as? [String: Any],
           let team = entitlements["com.apple.developer.team-identifier"] as? String, !team.isEmpty {
            return team
        }
        if let prefixes = dict["ApplicationIdentifierPrefix"] as? [String], let first = prefixes.first(where: { !$0.isEmpty }) {
            return first
        }
        return nil
    }

    /// Reads `ExpirationDate` from a `.mobileprovision` file at `url`, returning nil safely on missing, oversize or damaged files.
    public static func expiration(at url: URL, fileManager fm: FileManager = .default) -> Date? {
        guard let data = profileData(at: url, fileManager: fm) else { return nil }
        return expiration(fromProfile: data)
    }

    /// Extracts `ExpirationDate` from raw CMS-signed `.mobileprovision` bytes or a plain XML/binary property list.
    public static func expiration(fromProfile data: Data) -> Date? {
        plist(fromProfile: data)?["ExpirationDate"] as? Date
    }

    private static func profileData(at url: URL, fileManager fm: FileManager) -> Data? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 0, size <= Int64(maxProfileBytes),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return data
    }

    private static func plist(fromProfile data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maxProfileBytes else { return nil }
        if let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            return dict
        }
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        guard let start = data.range(of: xmlStart),
              let end = data.range(of: xmlEnd, in: start.lowerBound..<data.endIndex),
              start.lowerBound < end.upperBound else {
            return nil
        }
        let slice = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil)) as? [String: Any]
    }

    /// Returns the warning banner state when `expiration` is within 48 hours of `now` (including already expired), else nil.
    public static func warning(expiration: Date?, now: Date) -> SigningWarning? {
        guard let expiration else { return nil }
        let remaining = expiration.timeIntervalSince(now)
        guard remaining <= warningWindow else { return nil }
        if remaining <= 0 {
            return .expired
        }
        if remaining < 3600 {
            return .expiringSoon
        }
        let hours = max(1, Int((remaining / 3600).rounded(.down)))
        return .expiringHours(hours)
    }
}

/// Metadata file (`Documents/.shell-host.json`) written at app start so the Mac launcher can verify signing team, glue ABI,
/// shader chain, and remaining profile lifetime before hot-pushing a signed `DmGame<ID>.framework` into `Documents/Frameworks/`.
public struct ShellHostBeacon: Codable, Equatable, Sendable {
    public static let fileName = ".shell-host.json"
    public static let currentSchema = 1

    public var schema: Int
    public var glueVersion: Int
    public var bundleID: String
    public var teamID: String
    public var chain: String
    public var version: String
    public var expiresAtEpoch: Int64?

    public init(schema: Int = Self.currentSchema, glueVersion: Int = 1, bundleID: String, teamID: String,
                chain: String, version: String, expiresAtEpoch: Int64? = nil) {
        self.schema = schema
        self.glueVersion = glueVersion
        self.bundleID = bundleID
        self.teamID = teamID
        self.chain = chain
        self.version = version
        self.expiresAtEpoch = expiresAtEpoch
    }

    public static func write(to documents: URL, bundle: Bundle = .main, glueVersion: Int = 1, fileManager fm: FileManager = .default) {
        let info = bundle.infoDictionary ?? [:]
        let bundleID = (info["CFBundleIdentifier"] as? String) ?? bundle.bundleIdentifier ?? ""
        let rawChain = (info["DMChain"] as? String) ?? ""
        let chain = rawChain.isEmpty || rawChain.hasPrefix("b-") ? rawChain : "b-" + rawChain
        let version = (info["CFBundleShortVersionString"] as? String) ?? ""
        let teamID = ProvisioningProfile.bundledTeamIdentifier(bundle: bundle, fileManager: fm) ?? ""
        let expires = ProvisioningProfile.bundledExpiration(bundle: bundle, fileManager: fm).map { Int64($0.timeIntervalSince1970.rounded()) }
        let beacon = ShellHostBeacon(glueVersion: glueVersion, bundleID: bundleID, teamID: teamID,
                                     chain: chain, version: version, expiresAtEpoch: expires)
        guard let data = try? JSONEncoder().encode(beacon) else { return }
        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try? data.write(to: documents.appendingPathComponent(fileName), options: .atomic)
    }
}

/// Pure user-space Mach-O `LC_CODE_SIGNATURE` reader so `Documents/Frameworks/DmGame<ID>.framework` is checked before `dlopen`
/// can trigger a fatal `EXC_BAD_ACCESS (CODESIGNING)` kill on non-JIT iOS when unsigned or signed by another team.
public enum FrameworkSignature {
    public static let maxSignatureBytes = 16 * 1024 * 1024

    public struct Info: Equatable, Sendable {
        public var hasCodeSignature: Bool
        public var teamID: String?
        public var sliceOffset: UInt64
        public var signatureOffset: UInt32
        public var signatureSize: UInt32
    }

    private static let mhMagic64: UInt32 = 0xfeed_facf
    private static let fatMagic: UInt32 = 0xcafe_babe
    private static let fatMagic64: UInt32 = 0xcafe_babf
    private static let lcCodeSignature: UInt32 = 0x0000_001d
    private static let csMagicEmbeddedSignature: UInt32 = 0xfade_0cc0
    private static let csMagicCodeDirectory: UInt32 = 0xfade_0c02
    private static let csSupportsTeamID: UInt32 = 0x0002_0200
    private static let cpuTypeArm64: UInt32 = 0x0100_000c

    public static func inspect(executable url: URL, fileManager fm: FileManager = .default) -> Info? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let rawSize = (attrs[.size] as? NSNumber)?.uint64Value,
              rawSize >= 32,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        func readBytes(at offset: UInt64, count: Int) -> Data? {
            guard count > 0, offset <= rawSize, UInt64(count) <= rawSize - offset else { return nil }
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
                return data
            } catch {
                return nil
            }
        }
        func u32LE(_ d: Data, _ off: Int) -> UInt32 {
            UInt32(d[d.startIndex + off])
                | (UInt32(d[d.startIndex + off + 1]) << 8)
                | (UInt32(d[d.startIndex + off + 2]) << 16)
                | (UInt32(d[d.startIndex + off + 3]) << 24)
        }
        func u32BE(_ d: Data, _ off: Int) -> UInt32 {
            (UInt32(d[d.startIndex + off]) << 24)
                | (UInt32(d[d.startIndex + off + 1]) << 16)
                | (UInt32(d[d.startIndex + off + 2]) << 8)
                | UInt32(d[d.startIndex + off + 3])
        }
        func u64BE(_ d: Data, _ off: Int) -> UInt64 {
            (UInt64(u32BE(d, off)) << 32) | UInt64(u32BE(d, off + 4))
        }

        guard let head = readBytes(at: 0, count: 32) else { return nil }
        var sliceOffset: UInt64 = 0
        var sliceSize: UInt64 = rawSize
        let firstBE = u32BE(head, 0)
        if firstBE == fatMagic || firstBE == fatMagic64 {
            let nfat = u32BE(head, 4)
            let stride = firstBE == fatMagic64 ? 32 : 20
            guard nfat > 0, nfat <= 16, let table = readBytes(at: 8, count: Int(nfat) * stride) else { return nil }
            var chosen: (off: UInt64, size: UInt64)?
            for i in 0..<Int(nfat) {
                let base = i * stride
                let cputype = u32BE(table, base)
                let off = firstBE == fatMagic64 ? u64BE(table, base + 8) : UInt64(u32BE(table, base + 8))
                let sz = firstBE == fatMagic64 ? u64BE(table, base + 16) : UInt64(u32BE(table, base + 12))
                guard off <= rawSize, sz >= 32, sz <= rawSize - off else { continue }
                if cputype == cpuTypeArm64 || chosen == nil {
                    chosen = (off, sz)
                    if cputype == cpuTypeArm64 { break }
                }
            }
            guard let picked = chosen else { return nil }
            sliceOffset = picked.off
            sliceSize = picked.size
        }

        guard let mh = readBytes(at: sliceOffset, count: 32), u32LE(mh, 0) == mhMagic64 else { return nil }
        let ncmds = u32LE(mh, 16)
        let sizeofcmds = UInt64(u32LE(mh, 20))
        guard ncmds <= 4096, sizeofcmds <= sliceSize - 32, sizeofcmds <= 4 * 1024 * 1024,
              let cmds = readBytes(at: sliceOffset + 32, count: Int(sizeofcmds)) else { return nil }

        var cursor = 0
        var sigDataOff: UInt32 = 0
        var sigDataSize: UInt32 = 0
        for _ in 0..<ncmds {
            guard cursor <= cmds.count - 8 else { return nil }
            let cmd = u32LE(cmds, cursor)
            let cmdsize = Int(u32LE(cmds, cursor + 4))
            guard cmdsize >= 8, cmdsize <= cmds.count - cursor else { return nil }
            if cmd == lcCodeSignature, cmdsize >= 16 {
                sigDataOff = u32LE(cmds, cursor + 8)
                sigDataSize = u32LE(cmds, cursor + 12)
                break
            }
            cursor += cmdsize
        }

        guard sigDataOff > 0, sigDataSize >= 12,
              UInt64(sigDataOff) <= sliceSize,
              UInt64(sigDataSize) <= sliceSize - UInt64(sigDataOff),
              Int(sigDataSize) <= maxSignatureBytes,
              let blob = readBytes(at: sliceOffset + UInt64(sigDataOff), count: Int(sigDataSize)),
              u32BE(blob, 0) == csMagicEmbeddedSignature else {
            return Info(hasCodeSignature: false, teamID: nil, sliceOffset: sliceOffset, signatureOffset: 0, signatureSize: 0)
        }

        let sbLen = Int(u32BE(blob, 4))
        let count = Int(u32BE(blob, 8))
        guard sbLen >= 12, sbLen <= blob.count, count >= 0, count <= (sbLen - 12) / 8 else {
            return Info(hasCodeSignature: false, teamID: nil, sliceOffset: sliceOffset, signatureOffset: 0, signatureSize: 0)
        }

        var foundCD = false
        var teamID: String?
        for i in 0..<count {
            let entryOff = Int(u32BE(blob, 12 + i * 8 + 4))
            guard entryOff >= 12, entryOff <= sbLen - 8 else { continue }
            let magic = u32BE(blob, entryOff)
            let len = Int(u32BE(blob, entryOff + 4))
            guard magic == csMagicCodeDirectory, len >= 44, len <= sbLen - entryOff else { continue }
            foundCD = true
            let version = u32BE(blob, entryOff + 8)
            if version >= csSupportsTeamID, len >= 52 {
                let teamOff = Int(u32BE(blob, entryOff + 48))
                if teamOff >= 52, teamOff < len {
                    let start = blob.startIndex + entryOff + teamOff
                    let limit = blob.startIndex + entryOff + len
                    if let nul = blob[start..<limit].firstIndex(of: 0), nul > start,
                       let text = String(data: blob[start..<nul], encoding: .utf8), !text.isEmpty {
                        teamID = text
                    }
                }
            }
            break
        }
        guard foundCD else {
            return Info(hasCodeSignature: false, teamID: nil, sliceOffset: sliceOffset, signatureOffset: 0, signatureSize: 0)
        }
        return Info(hasCodeSignature: true, teamID: teamID, sliceOffset: sliceOffset,
                    signatureOffset: sigDataOff, signatureSize: sigDataSize)
    }

    /// Returns nil when `executable` is safe to pass to `dlopen`, or a readable refusal string when an external framework
    /// is missing, unsigned, or signed with a different Apple developer team than `hostTeamID`.
    public static func preflightExternal(executable: URL, appBundleURL: URL, hostTeamID: String?,
                                         fileManager fm: FileManager = .default) -> String? {
        let bundlePrefix = appBundleURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let exePath = executable.resolvingSymlinksInPath().standardizedFileURL.path
        if exePath.hasPrefix(bundlePrefix) {
            return nil
        }
        guard let info = inspect(executable: executable, fileManager: fm) else {
            return hostText("The game's framework executable could not be read. Install the game again from NX2Apple.")
        }
        guard info.hasCodeSignature else {
            return hostText("This game's framework in Documents/Frameworks is unsigned. Install the game again from NX2Apple.")
        }
        if let requiredTeam = hostTeamID, !requiredTeam.isEmpty {
            guard info.teamID == requiredTeam else {
                let actual = info.teamID ?? "ad-hoc"
                return hostText("This game's framework is signed for \(actual), while this app is signed for team \(requiredTeam). Install the game again from NX2Apple.")
            }
        }
        return nil
    }
}
