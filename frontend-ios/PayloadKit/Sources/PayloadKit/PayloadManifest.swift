import Foundation

public enum PayloadError: LocalizedError, CustomStringConvertible, Sendable, Equatable {
    case invalid(String)
    case signature(String)
    case incompatible(String)

    public var description: String {
        switch self {
        case .invalid(let detail): "payload: \(detail)"
        case .signature(let detail): "signature: \(detail)"
        case .incompatible(let detail): "compatibility: \(detail)"
        }
    }
    public var errorDescription: String? { description }
}

public struct PayloadCapabilities: Codable, Sendable, Equatable {
    public static let fileName = "shell-payloads.json"
    public static let protocolVersion = 2
    public var version: Int = protocolVersion
    public var bundleID: String
    public var teamID: String
    public var glueABI: Int
    public var osVersion: String
    public var executableSHA256: String?

    public init(bundleID: String, teamID: String, glueABI: Int = 1,
                osVersion: String = "26.0", executableSHA256: String? = nil) {
        self.bundleID = bundleID; self.teamID = teamID; self.glueABI = glueABI; self.osVersion = osVersion
        self.executableSHA256 = executableSHA256
    }
}

public struct PayloadManifest: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: UInt64
        public var sha256: String
        public var executable: Bool
        public init(path: String, bytes: UInt64, sha256: String, executable: Bool = false) {
            self.path = path; self.bytes = bytes; self.sha256 = sha256; self.executable = executable
        }
    }

    public var schema: Int = 1
    public var generation: String
    public var titleID: String
    public var displayVersion: String
    public var framework: String
    public var executable: String
    public var minOS: String
    public var glueABI: Int
    public var teamID: String
    public var files: [File]

    public init(generation: String = UUID().uuidString.lowercased(), titleID: String, displayVersion: String,
                framework: String, executable: String, minOS: String, glueABI: Int = 1, teamID: String, files: [File]) {
        self.generation = generation; self.titleID = titleID; self.displayVersion = displayVersion
        self.framework = framework; self.executable = executable; self.minOS = minOS
        self.glueABI = glueABI; self.teamID = teamID; self.files = files
    }

    public func validate() throws {
        guard schema == 1, UUID(uuidString: generation) != nil, generation == generation.lowercased(),
              titleID.count == 16, titleID.allSatisfy({ $0.isHexDigit && !$0.isLowercase }),
              framework.hasSuffix(".framework"), Self.safeComponent(framework),
              Self.safeComponent(executable), !teamID.isEmpty, teamID.count <= 128,
              Self.version(minOS) != nil, glueABI > 0,
              !files.isEmpty, files.count <= 65_535 else { throw PayloadError.invalid("manifest fields") }
        var paths = Set<String>()
        var folded = Set<String>()
        var total: UInt64 = 0
        for file in files {
            guard Self.safePath(file.path), file.path.hasPrefix(framework + "/"),
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  paths.insert(file.path).inserted, folded.insert(file.path.lowercased()).inserted,
                  file.bytes <= 128 << 30, total <= (128 << 30) - file.bytes else {
                throw PayloadError.invalid("file list")
            }
            total += file.bytes
        }
        for path in paths {
            let parts = path.split(separator: "/")
            for n in 1..<parts.count where paths.contains(parts.prefix(n).joined(separator: "/")) {
                throw PayloadError.invalid("file is also a directory")
            }
        }
        guard paths.contains(framework + "/" + executable),
              paths.contains(framework + "/game.manifest.json"),
              paths.contains(framework + "/Info.plist") else { throw PayloadError.invalid("framework files") }
    }

    public func compatible(with host: PayloadCapabilities) throws {
        try validate()
        guard host.version == PayloadCapabilities.protocolVersion, glueABI == host.glueABI,
              teamID == host.teamID, Self.version(minOS)! <= (Self.version(host.osVersion) ?? 0) else {
            throw PayloadError.incompatible("host version, signing team, or glue ABI")
        }
    }

    public static func safeComponent(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && text.utf8.count < 256 &&
        !text.contains("/") && !text.contains("\\") && !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    public static func safePath(_ text: String) -> Bool {
        text.utf8.count < 4096 && text.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeComponent(String($0)) }
    }

    public static func version(_ text: String) -> Int? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ (0..<1000).contains($0) }) else { return nil }
        return numbers[0] * 1_000_000 + (numbers.count > 1 ? numbers[1] * 1000 : 0) + (numbers.count > 2 ? numbers[2] : 0)
    }
}

public struct PayloadReceipt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case active, restartRequired, rejected }
    public var generation: String
    public var titleID: String
    public var state: State
    public var detail: String
    public init(generation: String, titleID: String, state: State, detail: String = "") {
        self.generation = generation; self.titleID = titleID; self.state = state; self.detail = detail
    }
}

/// Registry commits can succeed before a later receipt write fails. Preserve
/// those outcomes so the host still applies their catalogue/defaults changes.
public struct PayloadProcessingError: LocalizedError, Sendable {
    public let receipts: [PayloadReceipt]
    public let detail: String
    public var errorDescription: String? { detail }
}
