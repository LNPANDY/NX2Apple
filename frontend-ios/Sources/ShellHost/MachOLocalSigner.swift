import CryptoKit
import Darwin
import Foundation
import Security

public enum MachOLocalSignerError: LocalizedError, Equatable, Sendable {
    case outsideAllowedRoot
    case missingInfoPlist
    case invalidExecutableName
    case executableMissing
    case invalidMachO(String)
    case insufficientHeaderSpace
    case unsupportedKeyType
    case signatureFailed(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .outsideAllowedRoot:
            return hostText("Only external game frameworks in Documents/Frameworks can be signed on this device.")
        case .missingInfoPlist:
            return hostText("The game framework is missing Info.plist.")
        case .invalidExecutableName:
            return hostText("The game framework executable name is invalid.")
        case .executableMissing:
            return hostText("The game framework executable is missing.")
        case .invalidMachO:
            return hostText("The game framework binary is damaged or unsupported.")
        case .insufficientHeaderSpace:
            return hostText("The game framework binary does not have enough header space for a code signature.")
        case .unsupportedKeyType:
            return hostText("The imported certificate uses an unsupported signing key type.")
        case .signatureFailed:
            return hostText("The game framework could not be signed with the imported certificate.")
        case .ioFailed:
            return hostText("The signed game framework could not be saved.")
        }
    }
}

/// Receipt recorded beside a locally signed external framework so unchanged binaries skip redundant re-signing.
public struct LocalSignReceipt: Codable, Equatable, Sendable {
    public static let currentSchema = 2

    public var schema: Int = Self.currentSchema
    public var certFingerprint: String
    public var hostBundleID: String
    public var exeInode: UInt64
    public var exeSize: Int64
    public var exeMtimeSec: Int64
    public var exeMtimeNsec: Int64
}

/// Pure-Swift on-device Mach-O (`CS_SuperBlob` / `CS_CodeDirectory` v0x20400) and RFC 5652 CMS signer for
/// external `Documents/Frameworks/*.framework` bundles.
public enum MachOLocalSigner {
    private static let mhMagic64: UInt32 = 0xfeed_facf
    private static let cpuTypeArm64: UInt32 = 0x0100_000c
    private static let cpuTypeArm64_32: UInt32 = 0x0200_000c
    private static let lcSegment64: UInt32 = 0x0000_0019
    private static let lcSymtab: UInt32 = 0x0000_0002
    private static let lcDysymtab: UInt32 = 0x0000_000b
    private static let lcCodeSignature: UInt32 = 0x0000_001d
    private static let lcDyldInfo: UInt32 = 0x0000_0022
    private static let lcDyldInfoOnly: UInt32 = 0x8000_0022
    private static let lcFunctionStarts: UInt32 = 0x0000_0026
    private static let lcDataInCode: UInt32 = 0x0000_0029
    private static let lcDylibCodeSignDrs: UInt32 = 0x0000_002b
    private static let lcLinkerOptHint: UInt32 = 0x0000_002e
    private static let lcDyldExportsTrie: UInt32 = 0x8000_0033
    private static let lcDyldChainedFixups: UInt32 = 0x8000_0034

    private static let csMagicSuperBlob: UInt32 = 0xfade_0cc0
    private static let csMagicCodeDirectory: UInt32 = 0xfade_0c02
    private static let csMagicRequirements: UInt32 = 0xfade_0c01
    private static let csMagicRequirement: UInt32 = 0xfade_0c00
    private static let csMagicBlobWrapper: UInt32 = 0xfade_0b01
    private static let csSlotCodeDirectory: UInt32 = 0x0000_0000
    private static let csSlotRequirements: UInt32 = 0x0000_0002
    private static let csSlotCMSSignature: UInt32 = 0x0001_0000
    private static let csDesignatedRequirementType: UInt32 = 0x0000_0003
    private static let csCodeDirectoryVersion: UInt32 = 0x0002_0400
    private static let csHashTypeSHA256: UInt8 = 2
    private static let csPageSizeShiftArm64: UInt8 = 14
    private static let csPageSizeShiftDefault: UInt8 = 12
    private static let arm64VMPageSize: UInt64 = 0x4000

    /// Sidecar receipt path inside `hotFrameworksRoot` so the sealed `.framework` bundle stays 100% clean for strict verification.
    public static func receiptURL(for frameworkURL: URL) -> URL {
        let std = frameworkURL.standardizedFileURL
        return std.deletingLastPathComponent()
            .appendingPathComponent(".\(std.lastPathComponent).nx-local-sign.json")
    }

    /// Removes any local-signing sidecar receipt belonging to `frameworkURL`.
    public static func removeReceipt(for frameworkURL: URL, fileManager fm: FileManager = .default) {
        try? fm.removeItem(at: receiptURL(for: frameworkURL))
    }

    /// Returns true when `frameworkURL` is strictly located inside `allowedRoot`.
    public static func isInsideAllowedRoot(_ frameworkURL: URL, allowedRoot: URL) -> Bool {
        let rootStd = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
        let fwStd = frameworkURL.resolvingSymlinksInPath().standardizedFileURL.path
        return fwStd.hasPrefix(rootPrefix) && fwStd.count > rootPrefix.count
    }

    /// Checks whether an existing receipt matches the current schema, certificate, host bundle ID, and executable inode/size/mtime.
    public static func isReceiptValid(frameworkURL: URL, certFingerprint: String, hostBundleID: String,
                                      fileManager fm: FileManager = .default) -> Bool {
        let url = receiptURL(for: frameworkURL)
        guard let raw = try? Data(contentsOf: url),
              let receipt = try? JSONDecoder().decode(LocalSignReceipt.self, from: raw),
              receipt.schema == LocalSignReceipt.currentSchema,
              receipt.certFingerprint == certFingerprint,
              receipt.hostBundleID == hostBundleID,
              let exeURL = try? resolveExecutableURL(in: frameworkURL, fileManager: fm),
              let st = statFile(exeURL) else {
            return false
        }
        guard receipt.exeInode == UInt64(st.st_ino),
              receipt.exeSize == Int64(st.st_size),
              receipt.exeMtimeSec == Int64(st.st_mtimespec.tv_sec),
              receipt.exeMtimeNsec == Int64(st.st_mtimespec.tv_nsec) else {
            return false
        }
        return FrameworkSignature.inspect(executable: exeURL, fileManager: fm)?.hasCodeSignature == true
    }

    /// Signs `frameworkURL` on demand if no matching `.nx-local-sign.json` receipt exists.
    /// Returns `true` when signing was performed, `false` when the existing receipt was already current.
    @discardableResult
    public static func ensureSignedIfNeeded(frameworkURL: URL, allowedRoot: URL, hostBundleID: String,
                                            store: SideloadCertificateStore, now: Date = Date(),
                                            fileManager fm: FileManager = .default) throws -> Bool {
        guard isInsideAllowedRoot(frameworkURL, allowedRoot: allowedRoot) else {
            throw MachOLocalSignerError.outsideAllowedRoot
        }
        let signingIdentity = try store.loadIdentity()
        let effectiveBundleID = effectiveIdentifier(hostBundleID: hostBundleID, frameworkURL: frameworkURL)
        if isReceiptValid(frameworkURL: frameworkURL, certFingerprint: signingIdentity.summary.fingerprintHex,
                          hostBundleID: effectiveBundleID, fileManager: fm) {
            return false
        }
        try signFramework(at: frameworkURL, allowedRoot: allowedRoot, identity: signingIdentity,
                          hostBundleID: effectiveBundleID, now: now, fileManager: fm)
        return true
    }

    /// Signs an external `.framework` bundle in place (replacing the Mach-O executable via a fresh inode atomic rename)
    /// and writes the matching `.nx-local-sign.json` sidecar receipt.
    @discardableResult
    public static func signFramework(at frameworkURL: URL, allowedRoot: URL, identity: SideloadSigningIdentity,
                                     hostBundleID: String, now: Date = Date(),
                                     fileManager fm: FileManager = .default) throws -> LocalSignReceipt {
        guard isInsideAllowedRoot(frameworkURL, allowedRoot: allowedRoot) else {
            throw MachOLocalSignerError.outsideAllowedRoot
        }

        let infoPlistURL = frameworkURL.appendingPathComponent("Info.plist")
        guard let infoPlistData = try? Data(contentsOf: infoPlistURL) else {
            throw MachOLocalSignerError.missingInfoPlist
        }
        let executableURL = try resolveExecutableURL(in: frameworkURL, fileManager: fm)
        let executableName = executableURL.lastPathComponent

        // Step 1: Read original Mach-O binary and build `_CodeSignature/CodeResources` in memory first so any
        // malformed binary or signing error leaves the target framework directory completely untouched.
        let originalBinary: Data
        do {
            originalBinary = try Data(contentsOf: executableURL)
        } catch {
            throw MachOLocalSignerError.ioFailed(error.localizedDescription)
        }

        let codeResourcesData = try buildCodeResources(in: frameworkURL, executableName: executableName, fileManager: fm)
        let identifier = effectiveIdentifier(hostBundleID: hostBundleID, frameworkURL: frameworkURL)
        let teamID = identity.leafInfo.teamID
        let certChain = AppleCertificateAuthorities.completeChain(
            leafDER: identity.leafCertificateDER,
            providedChainDER: identity.chainCertificatesDER
        )
        let requirementsBlob = buildDesignatedRequirementsBlob(
            identifier: identifier,
            teamID: teamID,
            leafDER: identity.leafCertificateDER,
            isAppleAnchored: AppleCertificateAuthorities.isAnchoredToAppleRoot(chainDER: certChain)
        )

        let signedBinary = try signMachOBinary(
            originalBinary,
            identifier: identifier,
            teamID: teamID,
            infoPlistData: infoPlistData,
            codeResourcesData: codeResourcesData,
            requirementsBlob: requirementsBlob,
            identity: identity,
            certificateChainDER: certChain,
            signingDate: now
        )

        // Step 2: Persist `_CodeSignature/CodeResources` and atomically replace the executable with a fresh inode
        // so XNU binds a new vnode with no stale `cs_blobs` cache.
        let codeSigDir = frameworkURL.appendingPathComponent("_CodeSignature", isDirectory: true)
        do {
            try fm.createDirectory(at: codeSigDir, withIntermediateDirectories: true)
            try codeResourcesData.write(to: codeSigDir.appendingPathComponent("CodeResources"), options: .atomic)
        } catch {
            throw MachOLocalSignerError.ioFailed(error.localizedDescription)
        }
        try atomicWriteExecutable(signedBinary, to: executableURL)

        guard let st = statFile(executableURL) else {
            throw MachOLocalSignerError.ioFailed("stat failed after rename")
        }
        let receipt = LocalSignReceipt(
            certFingerprint: identity.summary.fingerprintHex,
            hostBundleID: identifier,
            exeInode: UInt64(st.st_ino),
            exeSize: Int64(st.st_size),
            exeMtimeSec: Int64(st.st_mtimespec.tv_sec),
            exeMtimeNsec: Int64(st.st_mtimespec.tv_nsec)
        )
        do {
            let encoded = try JSONEncoder().encode(receipt)
            try encoded.write(to: receiptURL(for: frameworkURL), options: .atomic)
        } catch {
            throw MachOLocalSignerError.ioFailed(error.localizedDescription)
        }
        return receipt
    }

    // MARK: - Bundle & Executable Resolution

    private static func effectiveIdentifier(hostBundleID: String, frameworkURL: URL) -> String {
        let trimmed = hostBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let info = try? Data(contentsOf: frameworkURL.appendingPathComponent("Info.plist")),
           let dict = (try? PropertyListSerialization.propertyList(from: info, options: [], format: nil)) as? [String: Any],
           let bundleID = dict["CFBundleIdentifier"] as? String, !bundleID.isEmpty {
            return bundleID
        }
        return frameworkURL.deletingPathExtension().lastPathComponent
    }

    private static func resolveExecutableURL(in frameworkURL: URL, fileManager fm: FileManager) throws -> URL {
        let infoPlistURL = frameworkURL.appendingPathComponent("Info.plist")
        var exeName = frameworkURL.deletingPathExtension().lastPathComponent
        if let data = try? Data(contentsOf: infoPlistURL),
           let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           let declared = dict["CFBundleExecutable"] as? String, !declared.isEmpty {
            exeName = declared
        }
        guard !exeName.isEmpty, !exeName.contains("/"), !exeName.contains("\\"), !exeName.contains(":"),
              exeName != ".", exeName != ".." else {
            throw MachOLocalSignerError.invalidExecutableName
        }
        let exeURL = frameworkURL.appendingPathComponent(exeName)
        guard isInsideAllowedRoot(exeURL, allowedRoot: frameworkURL),
              let attrs = try? fm.attributesOfItem(atPath: exeURL.path),
              attrs[.type] as? FileAttributeType == .typeRegular else {
            throw MachOLocalSignerError.executableMissing
        }
        return exeURL
    }

    // MARK: - _CodeSignature/CodeResources

    private static func buildCodeResources(in frameworkURL: URL, executableName: String,
                                           fileManager fm: FileManager) throws -> Data {
        let baseStd = frameworkURL.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: baseStd,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else {
            throw MachOLocalSignerError.ioFailed("failed to enumerate framework resources")
        }

        var files: [String: Any] = [:]
        var files2: [String: Any] = [:]
        let basePrefix = baseStd.path.hasSuffix("/") ? baseStd.path : baseStd.path + "/"

        for case let itemURL as URL in enumerator {
            let itemPath = itemURL.standardizedFileURL.path
            guard itemPath.hasPrefix(basePrefix) else { continue }
            let relPath = String(itemPath.dropFirst(basePrefix.count))
            guard !relPath.isEmpty else { continue }

            // Skip `_CodeSignature/` subtree completely.
            if relPath == "_CodeSignature" || relPath.hasPrefix("_CodeSignature/") {
                enumerator.skipDescendants()
                continue
            }

            let name = itemURL.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix(".\(executableName).signing-") || name == ".nx-local-sign.json" {
                continue
            }

            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values?.isDirectory == true { continue }

            // Skip the main Mach-O executable itself (sealed via CodeDirectory code slots).
            if relPath == executableName { continue }

            if values?.isSymbolicLink == true {
                if let target = try? fm.destinationOfSymbolicLink(atPath: itemURL.path) {
                    files[relPath] = ["symlink": target]
                    if relPath != "Info.plist" && relPath != "PkgInfo" {
                        files2[relPath] = ["symlink": target]
                    }
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let bytes: Data
            do {
                bytes = try Data(contentsOf: itemURL)
            } catch {
                throw MachOLocalSignerError.ioFailed(error.localizedDescription)
            }

            let sha1 = Data(Insecure.SHA1.hash(data: bytes))
            let sha256 = Data(SHA256.hash(data: bytes))
            files[relPath] = sha1
            // Apple's standard v2 resource rules omit Info.plist and PkgInfo from `files2` (Info.plist is sealed in Special Slot -1).
            if relPath != "Info.plist" && relPath != "PkgInfo" {
                files2[relPath] = [
                    "hash": sha1,
                    "hash2": sha256,
                ]
            }
        }

        let rules: [String: Any] = [
            "^.*": true,
            "^.*\\.lproj/": ["optional": true, "weight": 1000.0],
            "^.*\\.lproj/locversion.plist$": ["omit": true, "weight": 1100.0],
            "^Base\\.lproj/": ["weight": 1010.0],
            "^version.plist$": true,
        ]

        let rules2: [String: Any] = [
            ".*\\.dSYM($|/)": ["weight": 11.0],
            "^(.*/)?\\.DS_Store$": ["omit": true, "weight": 2000.0],
            "^.*": true,
            "^.*\\.lproj/": ["optional": true, "weight": 1000.0],
            "^.*\\.lproj/locversion.plist$": ["omit": true, "weight": 1100.0],
            "^Base\\.lproj/": ["weight": 1010.0],
            "^Info\\.plist$": ["omit": true, "weight": 20.0],
            "^PkgInfo$": ["omit": true, "weight": 20.0],
            "^embedded\\.provisionprofile$": ["weight": 20.0],
            "^version\\.plist$": ["weight": 20.0],
        ]

        let plist: [String: Any] = [
            "files": files,
            "files2": files2,
            "rules": rules,
            "rules2": rules2,
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            throw MachOLocalSignerError.ioFailed(error.localizedDescription)
        }
    }

    // MARK: - Mach-O 64-bit Parsing & Rewriting

    private struct MachOLayout {
        var cpuType: UInt32
        var ncmds: UInt32
        var sizeofcmds: UInt32
        var textFileOff: UInt64
        var textFileSize: UInt64
        var linkeditCmdOffset: Int
        var linkeditFileOff: UInt64
        var linkeditFileSize: UInt64
        var linkeditVMSize: UInt64
        var existingCodeSigCmdOffset: Int?
        var existingCodeSigDataOff: UInt32
        var minPayloadOffset: UInt64
        var maxNonSignatureEnd: UInt64
    }

    private static func parseMachO64(_ data: Data) throws -> MachOLayout {
        let totalSize = UInt64(data.count)
        guard totalSize >= 32 else {
            throw MachOLocalSignerError.invalidMachO("file smaller than mach_header_64")
        }
        guard readU32LE(data, 0) == mhMagic64 else {
            throw MachOLocalSignerError.invalidMachO("not a 64-bit little-endian Mach-O")
        }
        let cpuType = readU32LE(data, 4)
        let ncmds = readU32LE(data, 16)
        let sizeofcmds = readU32LE(data, 20)
        guard ncmds <= 4096,
              UInt64(sizeofcmds) <= totalSize - 32,
              sizeofcmds <= 4 * 1024 * 1024 else {
            throw MachOLocalSignerError.invalidMachO("load commands exceed binary bounds")
        }

        let cmdsEnd = 32 + Int(sizeofcmds)
        var cursor = 32

        var textFileOff: UInt64 = 0
        var textFileSize: UInt64 = 0
        var foundText = false
        var linkeditCmdOffset: Int?
        var linkeditFileOff: UInt64 = 0
        var linkeditFileSize: UInt64 = 0
        var linkeditVMSize: UInt64 = 0
        var existingCodeSigCmdOffset: Int?
        var existingCodeSigDataOff: UInt32 = 0
        var minPayloadOffset = totalSize
        var maxNonSigEnd: UInt64 = UInt64(cmdsEnd)

        func trackMinPayload(_ offset: UInt64) {
            if offset > 0 && offset < minPayloadOffset {
                minPayloadOffset = offset
            }
        }

        func trackEnd(_ offset: UInt64, _ size: UInt64) throws {
            guard size > 0 else { return }
            guard offset <= totalSize, size <= totalSize - offset else {
                throw MachOLocalSignerError.invalidMachO("load command payload exceeds file size")
            }
            trackMinPayload(offset)
            let end = offset + size
            if end > maxNonSigEnd { maxNonSigEnd = end }
        }

        for _ in 0..<ncmds {
            guard cursor <= cmdsEnd - 8 else {
                throw MachOLocalSignerError.invalidMachO("truncated load command header")
            }
            let cmd = readU32LE(data, cursor)
            let cmdsize = Int(readU32LE(data, cursor + 4))
            guard cmdsize >= 8, cmdsize <= cmdsEnd - cursor else {
                throw MachOLocalSignerError.invalidMachO("invalid load command size")
            }

            switch cmd {
            case lcSegment64:
                guard cmdsize >= 72 else {
                    throw MachOLocalSignerError.invalidMachO("truncated LC_SEGMENT_64")
                }
                let segName = readFixedCString(data, offset: cursor + 8, maxLen: 16)
                let vmsize = readU64LE(data, cursor + 32)
                let fileoff = readU64LE(data, cursor + 40)
                let filesize = readU64LE(data, cursor + 48)
                let nsects = Int(readU32LE(data, cursor + 64))

                if segName == "__TEXT" {
                    foundText = true
                    textFileOff = fileoff
                    textFileSize = filesize
                } else {
                    trackMinPayload(fileoff)
                }
                if segName == "__LINKEDIT" {
                    linkeditCmdOffset = cursor
                    linkeditFileOff = fileoff
                    linkeditFileSize = filesize
                    linkeditVMSize = vmsize
                    if fileoff > maxNonSigEnd { maxNonSigEnd = fileoff }
                } else {
                    try trackEnd(fileoff, filesize)
                }

                guard nsects >= 0, nsects <= (cmdsize - 72) / 80 else {
                    throw MachOLocalSignerError.invalidMachO("section count exceeds LC_SEGMENT_64 size")
                }
                for s in 0..<nsects {
                    let sectBase = cursor + 72 + s * 80
                    let sectOff = UInt64(readU32LE(data, sectBase + 48))
                    trackMinPayload(sectOff)
                }

            case lcCodeSignature:
                guard cmdsize >= 16 else {
                    throw MachOLocalSignerError.invalidMachO("truncated LC_CODE_SIGNATURE")
                }
                existingCodeSigCmdOffset = cursor
                existingCodeSigDataOff = readU32LE(data, cursor + 8)

            case lcSymtab:
                if cmdsize >= 24 {
                    let symoff = UInt64(readU32LE(data, cursor + 8))
                    let nsyms = UInt64(readU32LE(data, cursor + 12))
                    let stroff = UInt64(readU32LE(data, cursor + 16))
                    let strsize = UInt64(readU32LE(data, cursor + 20))
                    try trackEnd(symoff, nsyms * 16)
                    try trackEnd(stroff, strsize)
                }

            case lcDysymtab:
                if cmdsize >= 80 {
                    try trackEnd(UInt64(readU32LE(data, cursor + 32)), UInt64(readU32LE(data, cursor + 36)) * 8)
                    try trackEnd(UInt64(readU32LE(data, cursor + 40)), UInt64(readU32LE(data, cursor + 44)) * 52)
                    try trackEnd(UInt64(readU32LE(data, cursor + 48)), UInt64(readU32LE(data, cursor + 52)) * 4)
                    try trackEnd(UInt64(readU32LE(data, cursor + 56)), UInt64(readU32LE(data, cursor + 60)) * 4)
                    try trackEnd(UInt64(readU32LE(data, cursor + 64)), UInt64(readU32LE(data, cursor + 68)) * 8)
                    try trackEnd(UInt64(readU32LE(data, cursor + 72)), UInt64(readU32LE(data, cursor + 76)) * 8)
                }

            case lcDyldInfo, lcDyldInfoOnly:
                if cmdsize >= 48 {
                    for pairIdx in 0..<5 {
                        let off = UInt64(readU32LE(data, cursor + 8 + pairIdx * 8))
                        let sz = UInt64(readU32LE(data, cursor + 12 + pairIdx * 8))
                        try trackEnd(off, sz)
                    }
                }

            case lcFunctionStarts, lcDataInCode, lcDylibCodeSignDrs, lcLinkerOptHint, lcDyldExportsTrie, lcDyldChainedFixups:
                if cmdsize >= 16 {
                    try trackEnd(UInt64(readU32LE(data, cursor + 8)), UInt64(readU32LE(data, cursor + 12)))
                }

            default:
                break
            }

            cursor += cmdsize
        }

        guard foundText, let leOff = linkeditCmdOffset else {
            throw MachOLocalSignerError.invalidMachO("missing __TEXT or __LINKEDIT segment")
        }
        guard linkeditFileOff <= totalSize else {
            throw MachOLocalSignerError.invalidMachO("__LINKEDIT offset exceeds binary size")
        }

        return MachOLayout(
            cpuType: cpuType,
            ncmds: ncmds,
            sizeofcmds: sizeofcmds,
            textFileOff: textFileOff,
            textFileSize: textFileSize,
            linkeditCmdOffset: leOff,
            linkeditFileOff: linkeditFileOff,
            linkeditFileSize: linkeditFileSize,
            linkeditVMSize: linkeditVMSize,
            existingCodeSigCmdOffset: existingCodeSigCmdOffset,
            existingCodeSigDataOff: existingCodeSigDataOff,
            minPayloadOffset: minPayloadOffset,
            maxNonSignatureEnd: maxNonSigEnd
        )
    }

    private static func pageSizeShift(forCPU cpuType: UInt32) -> UInt8 {
        if cpuType == cpuTypeArm64 || cpuType == cpuTypeArm64_32 {
            return csPageSizeShiftArm64
        }
        return csPageSizeShiftDefault
    }

    private static func signMachOBinary(_ original: Data, identifier: String, teamID: String,
                                        infoPlistData: Data, codeResourcesData: Data, requirementsBlob: Data,
                                        identity: SideloadSigningIdentity, certificateChainDER: [Data],
                                        signingDate: Date) throws -> Data {
        let layout = try parseMachO64(original)
        let pageShift = pageSizeShift(forCPU: layout.cpuType)
        let originalSize = UInt64(original.count)

        let rawCodeEnd: UInt64
        if layout.existingCodeSigCmdOffset != nil,
           UInt64(layout.existingCodeSigDataOff) >= layout.linkeditFileOff,
           UInt64(layout.existingCodeSigDataOff) >= layout.maxNonSignatureEnd,
           UInt64(layout.existingCodeSigDataOff) <= originalSize {
            rawCodeEnd = UInt64(layout.existingCodeSigDataOff)
        } else {
            rawCodeEnd = max(originalSize, layout.maxNonSignatureEnd)
        }

        guard let codeLimit = alignUp(rawCodeEnd, to: 16),
              codeLimit >= layout.linkeditFileOff,
              codeLimit <= UInt64(UInt32.max) else {
            throw MachOLocalSignerError.invalidMachO("codeLimit out of valid 32-bit range")
        }

        var prefix = Data(original.prefix(Int(min(originalSize, codeLimit))))
        if UInt64(prefix.count) < codeLimit {
            prefix.append(Data(repeating: 0, count: Int(codeLimit - UInt64(prefix.count))))
        }

        let codeSigCmdOffset: Int
        if let existing = layout.existingCodeSigCmdOffset {
            guard existing >= 32, existing <= prefix.count, prefix.count - existing >= 16 else {
                throw MachOLocalSignerError.invalidMachO("existing LC_CODE_SIGNATURE out of bounds")
            }
            codeSigCmdOffset = existing
        } else {
            let insertOffset = 32 + Int(layout.sizeofcmds)
            guard layout.ncmds < UInt32.max,
                  layout.sizeofcmds <= UInt32.max - 16,
                  insertOffset >= 32,
                  insertOffset <= prefix.count,
                  prefix.count - insertOffset >= 16,
                  UInt64(insertOffset) <= layout.minPayloadOffset,
                  layout.minPayloadOffset - UInt64(insertOffset) >= 16 else {
                throw MachOLocalSignerError.insufficientHeaderSpace
            }
            let targetSlice = prefix[(prefix.startIndex + insertOffset)..<(prefix.startIndex + insertOffset + 16)]
            guard targetSlice.allSatisfy({ $0 == 0 }) else {
                throw MachOLocalSignerError.insufficientHeaderSpace
            }
            codeSigCmdOffset = insertOffset
            writeU32LE(&prefix, at: 16, layout.ncmds + 1)
            writeU32LE(&prefix, at: 20, layout.sizeofcmds + 16)
            writeU32LE(&prefix, at: codeSigCmdOffset, lcCodeSignature)
            writeU32LE(&prefix, at: codeSigCmdOffset + 4, 16)
        }

        let infoPlistHash = Data(SHA256.hash(data: infoPlistData))
        let requirementsHash = Data(SHA256.hash(data: requirementsBlob))
        let codeResourcesHash = Data(SHA256.hash(data: codeResourcesData))

        // Converge strictly on a SuperBlob byte length matching the written Mach-O header fields.
        // RSA always converges exactly on attempt 1; ECDSA DER signatures vary by 0-2 bytes and either converge
        // exactly on attempts 1-2 or reserve a 16-byte-aligned ceiling from attempt 2 onward for guaranteed convergence.
        var allocatedSigSize: UInt32 = 0
        var finalSuperBlob = Data()
        var converged = false

        for attempt in 0..<8 {
            let linkeditBytesBeforeSig = codeLimit - layout.linkeditFileOff
            guard UInt64(allocatedSigSize) <= UInt64.max - linkeditBytesBeforeSig else {
                throw MachOLocalSignerError.invalidMachO("__LINKEDIT filesize overflow")
            }
            let newLinkeditFileSize = linkeditBytesBeforeSig + UInt64(allocatedSigSize)
            guard let alignedVM = alignUp(newLinkeditFileSize, to: arm64VMPageSize) else {
                throw MachOLocalSignerError.invalidMachO("__LINKEDIT vmsize overflow")
            }
            let alignedLinkeditVMSize = max(layout.linkeditVMSize, alignedVM)

            writeU32LE(&prefix, at: codeSigCmdOffset + 8, UInt32(codeLimit))
            writeU32LE(&prefix, at: codeSigCmdOffset + 12, allocatedSigSize)
            writeU64LE(&prefix, at: layout.linkeditCmdOffset + 32, alignedLinkeditVMSize)
            writeU64LE(&prefix, at: layout.linkeditCmdOffset + 48, newLinkeditFileSize)

            let codeDirectory = buildCodeDirectory(
                machOPrefix: prefix,
                codeLimit: UInt32(codeLimit),
                pageSizeShift: pageShift,
                identifier: identifier,
                teamID: teamID,
                execSegBase: layout.textFileOff,
                execSegLimit: layout.textFileSize,
                infoPlistHash: infoPlistHash,
                requirementsHash: requirementsHash,
                codeResourcesHash: codeResourcesHash
            )
            let cmsBlob = try buildCMSSignatureBlob(
                codeDirectory: codeDirectory,
                identity: identity,
                certificateChainDER: certificateChainDER,
                signingDate: signingDate
            )
            let superBlob = buildSuperBlob(
                codeDirectory: codeDirectory,
                requirementsBlob: requirementsBlob,
                cmsBlob: cmsBlob
            )
            guard superBlob.count <= Int(UInt32.max) else {
                throw MachOLocalSignerError.signatureFailed("signature blob exceeds 32-bit size limit")
            }

            if attempt > 0 && superBlob.count == Int(allocatedSigSize) {
                finalSuperBlob = superBlob
                converged = true
                break
            }
            if attempt >= 3 && superBlob.count <= Int(allocatedSigSize) {
                var padded = superBlob
                padded.append(Data(repeating: 0, count: Int(allocatedSigSize) - superBlob.count))
                finalSuperBlob = padded
                converged = true
                break
            }
            if attempt >= 2 {
                let ceilingBase = UInt64(max(Int(allocatedSigSize), superBlob.count))
                guard ceilingBase <= UInt64(UInt32.max) - 16,
                      let reserved = alignUp(ceilingBase + 16, to: 16),
                      reserved <= UInt64(UInt32.max) else {
                    throw MachOLocalSignerError.signatureFailed("signature blob size overflow")
                }
                allocatedSigSize = UInt32(reserved)
            } else {
                allocatedSigSize = UInt32(superBlob.count)
            }
        }

        guard converged, finalSuperBlob.count == Int(allocatedSigSize) else {
            throw MachOLocalSignerError.signatureFailed("signature blob size did not converge")
        }

        var output = prefix
        output.append(finalSuperBlob)
        return output
    }

    // MARK: - CS_SuperBlob / CS_CodeDirectory / CS_RequirementsBlob

    /// Builds a `CS_RequirementsBlob` carrying a standard `kSecDesignatedRequirementType` (3) requirement matching
    /// `codesign`'s `DRMaker`: `anchor apple generic` + `subject.OU` for Apple-anchored chains, or `certificate leaf = H"..."`
    /// for non-Apple / self-signed certificates.
    static func buildDesignatedRequirementsBlob(identifier: String, teamID: String, leafDER: Data,
                                                isAppleAnchored: Bool) -> Data {
        func appendReqData(_ out: inout Data, _ bytes: Data) {
            appendU32BE(&out, UInt32(bytes.count))
            out.append(bytes)
            let pad = (4 - (bytes.count % 4)) % 4
            if pad > 0 {
                out.append(Data(repeating: 0, count: pad))
            }
        }

        // Apple CS requirement opcodes (Security/CSCommon & drmaker.cpp):
        // kind = 1 (opExpr), opIdent = 2, opAnchorHash = 4, opAnd = 6, opCertField = 11, opAppleGenericAnchor = 15, matchEqual = 1.
        var expr = Data()
        if isAppleAnchored {
            if !teamID.isEmpty {
                appendU32BE(&expr, 6) // outer opAnd
            }
            appendU32BE(&expr, 6) // inner opAnd
            appendU32BE(&expr, 2) // opIdent
            appendReqData(&expr, Data(identifier.utf8))
            appendU32BE(&expr, 15) // opAppleGenericAnchor
            if !teamID.isEmpty {
                appendU32BE(&expr, 11) // opCertField
                appendU32BE(&expr, 0)  // slot 0 = leaf certificate
                appendReqData(&expr, Data("subject.OU".utf8))
                appendU32BE(&expr, 1)  // matchEqual
                appendReqData(&expr, Data(teamID.utf8))
            }
        } else {
            let leafSHA1 = Data(Insecure.SHA1.hash(data: leafDER))
            appendU32BE(&expr, 6) // opAnd
            appendU32BE(&expr, 2) // opIdent
            appendReqData(&expr, Data(identifier.utf8))
            appendU32BE(&expr, 4) // opAnchorHash
            appendU32BE(&expr, 0) // slot 0 = leaf certificate
            appendReqData(&expr, leafSHA1)
        }

        var singleReq = Data()
        let reqLength = UInt32(12 + expr.count)
        appendU32BE(&singleReq, csMagicRequirement)
        appendU32BE(&singleReq, reqLength)
        appendU32BE(&singleReq, 1) // kind = 1 (opExpr)
        singleReq.append(expr)

        var out = Data()
        let totalLength = UInt32(20 + singleReq.count)
        appendU32BE(&out, csMagicRequirements)
        appendU32BE(&out, totalLength)
        appendU32BE(&out, 1) // count = 1
        appendU32BE(&out, csDesignatedRequirementType)
        appendU32BE(&out, 20) // offset of the first requirement blob
        out.append(singleReq)
        return out
    }

    private static func buildCodeDirectory(machOPrefix: Data, codeLimit: UInt32, pageSizeShift: UInt8,
                                           identifier: String, teamID: String,
                                           execSegBase: UInt64, execSegLimit: UInt64,
                                           infoPlistHash: Data, requirementsHash: Data, codeResourcesHash: Data) -> Data {
        let csPageSize = 1 << Int(pageSizeShift)
        let headerSize: UInt32 = 88
        let nSpecialSlots: UInt32 = 3
        let nCodeSlots = UInt32((Int(codeLimit) + csPageSize - 1) / csPageSize)

        var identBytes = Data(identifier.utf8)
        identBytes.append(0)

        var teamBytes = Data()
        let teamOffset: UInt32
        if !teamID.isEmpty {
            teamOffset = headerSize + UInt32(identBytes.count)
            teamBytes.append(Data(teamID.utf8))
            teamBytes.append(0)
        } else {
            teamOffset = 0
        }

        let specialSlotsOffset = headerSize + UInt32(identBytes.count) + UInt32(teamBytes.count)
        let hashOffset = specialSlotsOffset + nSpecialSlots * 32
        let totalLength = hashOffset + nCodeSlots * 32

        var cd = Data()
        cd.reserveCapacity(Int(totalLength))
        appendU32BE(&cd, csMagicCodeDirectory)  // 0: magic
        appendU32BE(&cd, totalLength)           // 4: length
        appendU32BE(&cd, csCodeDirectoryVersion)// 8: version (0x20400)
        appendU32BE(&cd, 0)                     // 12: flags
        appendU32BE(&cd, hashOffset)            // 16: hashOffset
        appendU32BE(&cd, headerSize)            // 20: identOffset
        appendU32BE(&cd, nSpecialSlots)         // 24: nSpecialSlots
        appendU32BE(&cd, nCodeSlots)            // 28: nCodeSlots
        appendU32BE(&cd, codeLimit)             // 32: codeLimit
        cd.append(32)                           // 36: hashSize
        cd.append(csHashTypeSHA256)             // 37: hashType (SHA-256)
        cd.append(0)                            // 38: platform
        cd.append(pageSizeShift)                // 39: pageSize (2^14 = 16384 on arm64, 2^12 = 4096 otherwise)
        appendU32BE(&cd, 0)                     // 40: spare2
        appendU32BE(&cd, 0)                     // 44: scatterOffset (v0x20100)
        appendU32BE(&cd, teamOffset)            // 48: teamOffset (v0x20200)
        appendU32BE(&cd, 0)                     // 52: spare3 (v0x20300)
        appendU64BE(&cd, 0)                     // 56: codeLimit64 (v0x20300)
        appendU64BE(&cd, execSegBase)           // 64: execSegBase (v0x20400)
        appendU64BE(&cd, execSegLimit)          // 72: execSegLimit (v0x20400)
        appendU64BE(&cd, 0)                     // 80: execSegFlags (v0x20400, 0 for dylib/framework)

        cd.append(identBytes)
        cd.append(teamBytes)

        // Special slots in ascending index order: -3 (CodeResources), -2 (Requirements), -1 (Info.plist).
        cd.append(codeResourcesHash)
        cd.append(requirementsHash)
        cd.append(infoPlistHash)

        // Code page hashes from slice offset 0 up to codeLimit.
        let limitInt = Int(codeLimit)
        var pageStart = 0
        while pageStart < limitInt {
            let pageEnd = min(pageStart + csPageSize, limitInt)
            let pageSlice = machOPrefix.subdata(in: pageStart..<pageEnd)
            cd.append(Data(SHA256.hash(data: pageSlice)))
            pageStart = pageEnd
        }

        return cd
    }

    private static func buildSuperBlob(codeDirectory: Data, requirementsBlob: Data, cmsBlob: Data) -> Data {
        let slots: [(type: UInt32, data: Data)] = [
            (csSlotCodeDirectory, codeDirectory),
            (csSlotRequirements, requirementsBlob),
            (csSlotCMSSignature, cmsBlob),
        ]
        let headerBytes = 12 + slots.count * 8
        let totalLength = headerBytes + slots.reduce(0) { $0 + $1.data.count }

        var sb = Data()
        sb.reserveCapacity(totalLength)
        appendU32BE(&sb, csMagicSuperBlob)
        appendU32BE(&sb, UInt32(totalLength))
        appendU32BE(&sb, UInt32(slots.count))

        var offset = headerBytes
        for slot in slots {
            appendU32BE(&sb, slot.type)
            appendU32BE(&sb, UInt32(offset))
            offset += slot.data.count
        }
        for slot in slots {
            sb.append(slot.data)
        }
        return sb
    }

    // MARK: - RFC 5652 CMS SignedData

    private static func buildCMSSignatureBlob(codeDirectory: Data, identity: SideloadSigningIdentity,
                                              certificateChainDER: [Data], signingDate: Date) throws -> Data {
        let cmsDER = try buildCMSContentInfo(
            codeDirectory: codeDirectory,
            identity: identity,
            certificateChainDER: certificateChainDER,
            signingDate: signingDate
        )
        var wrapper = Data()
        wrapper.reserveCapacity(8 + cmsDER.count)
        appendU32BE(&wrapper, csMagicBlobWrapper)
        appendU32BE(&wrapper, UInt32(8 + cmsDER.count))
        wrapper.append(cmsDER)
        return wrapper
    }

    private static func buildCMSContentInfo(codeDirectory: Data, identity: SideloadSigningIdentity,
                                            certificateChainDER: [Data], signingDate: Date) throws -> Data {
        let oidData = ASN1DER.oid([1, 2, 840, 113549, 1, 7, 1])
        let oidSignedData = ASN1DER.oid([1, 2, 840, 113549, 1, 7, 2])
        let oidSHA256 = ASN1DER.oid([2, 16, 840, 1, 101, 3, 4, 2, 1])
        let oidContentType = ASN1DER.oid([1, 2, 840, 113549, 1, 9, 3])
        let oidMessageDigest = ASN1DER.oid([1, 2, 840, 113549, 1, 9, 4])
        let oidSigningTime = ASN1DER.oid([1, 2, 840, 113549, 1, 9, 5])
        let oidAppleCDHashesPlist = ASN1DER.oid([1, 2, 840, 113635, 100, 9, 1])
        let oidAppleCDHashesV2 = ASN1DER.oid([1, 2, 840, 113635, 100, 9, 2])

        let sha256AlgID = ASN1DER.sequence([oidSHA256, ASN1DER.null()])
        let cdHash = Data(SHA256.hash(data: codeDirectory))
        let cdHash20Base64 = Data(cdHash.prefix(20)).base64EncodedString()
        let cdHashesPlistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>cdhashes</key>
        \t<array>
        \t\t<data>\(cdHash20Base64)</data>
        \t</array>
        </dict>
        </plist>
        """

        let attrContentType = ASN1DER.sequence([oidContentType, ASN1DER.set([oidData])])
        let attrSigningTime = ASN1DER.sequence([oidSigningTime, ASN1DER.set([ASN1DER.utcTime(signingDate)])])
        let attrMessageDigest = ASN1DER.sequence([oidMessageDigest, ASN1DER.set([ASN1DER.octetString(cdHash)])])
        let attrCDHashesPlist = ASN1DER.sequence([
            oidAppleCDHashesPlist,
            ASN1DER.set([ASN1DER.octetString(Data(cdHashesPlistXML.utf8))]),
        ])
        let attrCDHashesV2 = ASN1DER.sequence([
            oidAppleCDHashesV2,
            ASN1DER.set([ASN1DER.sequence([oidSHA256, ASN1DER.octetString(cdHash)])]),
        ])

        // X.690 DER rule: SET OF Attribute elements must be sorted in ascending lexicographical order of their DER encoding.
        let sortedAttrs = [attrContentType, attrSigningTime, attrMessageDigest, attrCDHashesPlist, attrCDHashesV2]
            .sorted { $0.lexicographicallyPrecedes($1) }
        var sortedAttrsBody = Data()
        for attr in sortedAttrs { sortedAttrsBody.append(attr) }

        let signedAttrsForSigning = ASN1DER.tlv(tag: 0x31, content: sortedAttrsBody)
        let signedAttrsImplicit = ASN1DER.tlv(tag: 0xA0, content: sortedAttrsBody)

        let (secAlgorithm, sigAlgDER) = try signingAlgorithm(for: identity.privateKey)
        var cfError: Unmanaged<CFError>?
        guard let signatureData = SecKeyCreateSignature(
            identity.privateKey,
            secAlgorithm,
            signedAttrsForSigning as CFData,
            &cfError
        ) as Data? else {
            let reason = cfError?.takeRetainedValue().localizedDescription ?? "SecKeyCreateSignature failed"
            throw MachOLocalSignerError.signatureFailed(reason)
        }

        // Preserve exact raw DER issuer and serialNumber TLVs from leaf TBSCertificate (zero re-encoding drift).
        let issuerAndSerial = ASN1DER.sequence([
            identity.leafInfo.issuerRawTLV,
            identity.leafInfo.serialNumberRawTLV,
        ])

        let signerInfo = ASN1DER.sequence([
            ASN1DER.integer(1),
            issuerAndSerial,
            sha256AlgID,
            signedAttrsImplicit,
            sigAlgDER,
            ASN1DER.octetString(signatureData),
        ])

        let encapContentInfo = ASN1DER.sequence([oidData])
        // SignedData.certificates is `[0] IMPLICIT CertificateSet` (SET OF): sort elements by DER encoding per X.690.
        let sortedCertificates = certificateChainDER.sorted { $0.lexicographicallyPrecedes($1) }
        let certificatesImplicit = ASN1DER.contextImplicitConstructed(0, items: sortedCertificates)

        let signedData = ASN1DER.sequence([
            ASN1DER.integer(1),
            ASN1DER.set([sha256AlgID]),
            encapContentInfo,
            certificatesImplicit,
            ASN1DER.set([signerInfo]),
        ])

        return ASN1DER.sequence([
            oidSignedData,
            ASN1DER.contextExplicit(0, content: signedData),
        ])
    }

    private static func signingAlgorithm(for privateKey: SecKey) throws -> (SecKeyAlgorithm, Data) {
        guard let attrs = SecKeyCopyAttributes(privateKey) as? [String: Any],
              let keyType = attrs[kSecAttrKeyType as String] as? String else {
            throw MachOLocalSignerError.unsupportedKeyType
        }
        if keyType == (kSecAttrKeyTypeRSA as String) {
            // sha256WithRSAEncryption (1.2.840.113549.1.1.11) with NULL parameters.
            let algID = ASN1DER.sequence([ASN1DER.oid([1, 2, 840, 113549, 1, 1, 11]), ASN1DER.null()])
            return (.rsaSignatureMessagePKCS1v15SHA256, algID)
        }
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) || keyType == (kSecAttrKeyTypeEC as String) {
            // ecdsa-with-SHA256 (1.2.840.10045.4.3.2); per RFC 5758 parameters MUST be omitted.
            let algID = ASN1DER.sequence([ASN1DER.oid([1, 2, 840, 10045, 4, 3, 2])])
            return (.ecdsaSignatureMessageX962SHA256, algID)
        }
        throw MachOLocalSignerError.unsupportedKeyType
    }

    // MARK: - Atomic Fresh-Inode Replacement & Low-Level Helpers

    private static func atomicWriteExecutable(_ data: Data, to targetURL: URL) throws {
        let dir = targetURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".\(targetURL.lastPathComponent).signing-\(UUID().uuidString)")
        let tempPath = tempURL.path
        let targetPath = targetURL.path

        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o755)
        guard fd >= 0 else {
            throw MachOLocalSignerError.ioFailed("open temp executable failed (errno \(errno))")
        }

        var cleanupTemp = true
        defer {
            if cleanupTemp {
                Darwin.unlink(tempPath)
            }
        }

        let writeErr: Int32? = data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return nil }
            var written = 0
            while written < rawBuf.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuf.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                written += n
            }
            return nil
        }

        if let err = writeErr {
            Darwin.close(fd)
            throw MachOLocalSignerError.ioFailed("write failed (errno \(err))")
        }
        if Darwin.fchmod(fd, 0o755) != 0 {
            let err = errno
            Darwin.close(fd)
            throw MachOLocalSignerError.ioFailed("fchmod failed (errno \(err))")
        }
        if Darwin.fsync(fd) != 0 {
            let err = errno
            Darwin.close(fd)
            throw MachOLocalSignerError.ioFailed("fsync failed (errno \(err))")
        }
        if Darwin.close(fd) != 0 {
            throw MachOLocalSignerError.ioFailed("close failed (errno \(errno))")
        }

        if Darwin.rename(tempPath, targetPath) != 0 {
            throw MachOLocalSignerError.ioFailed("rename failed (errno \(errno))")
        }
        cleanupTemp = false
    }

    private static func statFile(_ url: URL) -> stat? {
        var st = stat()
        let rc = Darwin.lstat(url.path, &st)
        guard rc == 0 else { return nil }
        return st
    }

    private static func alignUp(_ value: UInt64, to alignment: UInt64) -> UInt64? {
        guard alignment > 0 else { return nil }
        let rem = value % alignment
        if rem == 0 { return value }
        let pad = alignment - rem
        guard value <= UInt64.max - pad else { return nil }
        return value + pad
    }

    private static func readU32LE(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func readU64LE(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readU32LE(data, offset)) | (UInt64(readU32LE(data, offset + 4)) << 32)
    }

    private static func writeU32LE(_ data: inout Data, at offset: Int, _ value: UInt32) {
        let i = data.startIndex + offset
        data[i] = UInt8(value & 0xff)
        data[i + 1] = UInt8((value >> 8) & 0xff)
        data[i + 2] = UInt8((value >> 16) & 0xff)
        data[i + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func writeU64LE(_ data: inout Data, at offset: Int, _ value: UInt64) {
        writeU32LE(&data, at: offset, UInt32(value & 0xffff_ffff))
        writeU32LE(&data, at: offset + 4, UInt32(value >> 32))
    }

    private static func appendU32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendU64BE(_ data: inout Data, _ value: UInt64) {
        appendU32BE(&data, UInt32(value >> 32))
        appendU32BE(&data, UInt32(value & 0xffff_ffff))
    }

    private static func readFixedCString(_ data: Data, offset: Int, maxLen: Int) -> String {
        let start = data.startIndex + offset
        let end = min(start + maxLen, data.endIndex)
        let slice = data[start..<end]
        let trimmed = slice.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .utf8) ?? ""
    }
}
