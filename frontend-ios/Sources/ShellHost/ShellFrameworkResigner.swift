import Foundation
import Darwin
import ZsignC

enum ShellSigningError: Error { case signature(String), invalid(String), kernel(String, Int32) }

/// Re-signs private staged copies only. Never operate on an installed or loaded image.
enum ShellFrameworkResigner {
    static func sign(framework: URL, expectedTeamID: String,
                     pkcs12: URL, profile: URL, password: String) throws {
        guard !expectedTeamID.isEmpty, !expectedTeamID.contains("\0") else { throw ShellSigningError.signature("missing host signing team") }
        let files = try Self.nativeFiles(framework: framework)
        guard files.count == 1, let file = files.first else {
            throw ShellSigningError.invalid("frameworks with nested native code need resource resealing; re-sign this game on your Mac")
        }
        let identifier = try Self.bundleIdentifier(framework: framework)
        guard pkcs12.isFileURL, profile.isFileURL,
              !password.contains("\0") else { throw ShellSigningError.signature("invalid local identity") }
        let info = framework.appendingPathComponent("Info.plist")
        let resources = framework.appendingPathComponent("_CodeSignature/CodeResources")
        let hasResources = FileManager.default.fileExists(atPath: resources.path)
        if hasResources {
            let data = try boundedMetadata(resources, limit: 16 * 1024 * 1024)
            guard let seal = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  !["files", "files2"].contains(where: {
                      (seal[$0] as? [String: Any])?[file.lastPathComponent] != nil
                  }) else {
                throw ShellSigningError.invalid("resource seal includes the main executable; re-sign this game on your Mac")
            }
        }
        var message = [CChar](repeating: 0, count: 1024)
        let result = zsign_sign_library_with_resources(file.path, pkcs12.path, password,
            profile.path, expectedTeamID, identifier, info.path, hasResources ? resources.path : "",
            &message, message.count)
        guard result == 0 else {
            throw ShellSigningError.signature(String(decoding: message.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        guard let signature = FrameworkSignature.inspect(executable: file),
              signature.teamID == expectedTeamID else {
            throw ShellSigningError.signature("signed image team mismatch")
        }
        try validate(file, signature: signature)
    }

    static func bundleIdentifier(framework: URL) throws -> String {
        let info = try bundleInfo(framework: framework)
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              identifier.utf8.count <= 255, !identifier.contains("\0") else {
            throw ShellSigningError.invalid("framework bundle identifier")
        }
        return identifier
    }

    /// Bound the metadata read itself, not only a prior file size check.
    private static func bundleInfo(framework: URL) throws -> [String: Any] {
        let data = try boundedMetadata(framework.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ShellSigningError.invalid("framework metadata")
        }
        return info
    }

    private static func boundedMetadata(_ url: URL, limit: Int = 1 << 20) throws -> Data {
        guard (((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? (limit + 1)) <= limit else { throw ShellSigningError.invalid("framework metadata too large") }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ShellSigningError.invalid("framework metadata too large") }
        return data
    }

    static func nativeFiles(framework: URL) throws -> [URL] {
        let fm = FileManager.default
        guard framework.isFileURL,
              try fm.attributesOfItem(atPath: framework.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ShellSigningError.invalid("staged framework directory")
        }
        // Do not skip hidden entries. Reject links and unusual filesystem types
        // even when they would not otherwise be selected for signing.
        var result: [URL] = []
        var count = 0
        func visit(_ directory: URL, depth: Int = 0) throws {
            guard depth <= 64 else { throw ShellSigningError.invalid("framework nesting limit") }
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                count += 1
                guard count <= 100_000 else { throw ShellSigningError.invalid("framework entry limit") }
                let attributes = try fm.attributesOfItem(atPath: file.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: try visit(file, depth: depth + 1)
                case .typeRegular:
                    guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                        throw ShellSigningError.invalid("hard-linked staged file")
                    }
                    if try Self.isLibrary(file) { result.append(file) }
                default: throw ShellSigningError.invalid("non-regular staged framework entry")
                }
            }
        }
        try visit(framework)
        // An unrelated nested library must never stand in for the main image.
        // Read metadata only after rejecting links throughout the tree.
        let info = try bundleInfo(framework: framework)
        let manifest = try GameManifest.parse(boundedMetadata(framework.appendingPathComponent("game.manifest.json")))
        guard let executable = info["CFBundleExecutable"] as? String,
              executable == manifest.frameworkExecutable,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\0"),
              result.contains(where: { $0.standardizedFileURL.path ==
                  framework.appendingPathComponent(executable).standardizedFileURL.path }) else {
            throw ShellSigningError.invalid("framework main executable is not a supported native library")
        }
        return result.sorted { $0.path < $1.path }
    }
    static func isLibrary(_ url: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bytes = [UInt8](try input.read(upToCount: 16) ?? Data())
        guard bytes.count >= 4 else { return false }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        let magic = word(0)
        if [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            // CAFEBABE also identifies Java class resources. Require a plausible
            // fat header and a recognized host CPU before classifying it as code.
            guard bytes.count >= 12 else { return false }
            let swapped = magic == 0xbebafeca || magic == 0xbfbafeca
            let architectures = swapped ? word(4).byteSwapped : word(4)
            let cpu = swapped ? word(8).byteSwapped : word(8)
            guard architectures > 0, architectures <= 4096,
                  [UInt32(7), 12, 18].contains(cpu & 0x00ffffff) else { return false }
            throw ShellSigningError.invalid("universal native images are not supported")
        }
        guard [UInt32(0xfeedface), 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else { return false }
        guard bytes.count == 16 else { throw ShellSigningError.invalid("truncated native image") }
        let swapped = magic == 0xcefaedfe || magic == 0xcffaedfe
        let kind = swapped ? word(12).byteSwapped : word(12)
        // Metal/GPU objects and other resources are not host-loadable libraries.
        guard [UInt32(2), 6, 8].contains(kind) else { return false }
        guard magic == 0xfeedfacf, word(4) == 0x0100000c, kind != 2 else {
            throw ShellSigningError.invalid("unsupported native image")
        }
        return true
    }

    /// Reuse the signature offsets already inspected above; the kernel decides
    /// whether this process may load the staged image.
    private static func validate(_ file: URL, signature: FrameworkSignature.Info) throws {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ShellSigningError.signature("cannot open signed library") }
        defer { close(fd) }
        var info = fsignatures_t()
        info.fs_file_start = off_t(signature.sliceOffset)
        info.fs_blob_start = UnsafeMutableRawPointer(bitPattern: Int(signature.signatureOffset))
        info.fs_blob_size = Int(signature.signatureSize)
        guard fcntl(fd, F_ADDFILESIGS_RETURN, &info) == 0 else {
            throw ShellSigningError.kernel("signature registration", errno)
        }
        var message = [CChar](repeating: 0, count: 512)
        let result = message.withUnsafeMutableBytes { buffer in
            var check = fchecklv_t()
            check.lv_file_start = off_t(signature.sliceOffset)
            check.lv_error_message = buffer.baseAddress
            check.lv_error_message_size = buffer.count
            let status = fcntl(fd, F_CHECK_LV, &check)
            return (status, errno)
        }
        guard result.0 == 0 else { throw ShellSigningError.kernel("library validation", result.1) }
    }

}
