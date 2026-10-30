import Foundation

/// `game.manifest.json`, schema 1, as the Route C plan defines it (docs/launcher-c-plan.md, "Manifest"). Written at
/// build time, read by the shell. A reader ignores keys it does not know.
public struct GameManifest: Decodable, Equatable, Sendable {
    public var schema: Int
    public var titleID: String
    public var name: String
    public var displayVersion: String
    public var packageVersion: String
    public var modules: [String]
    public var nroCount: Int
    /// `b-<hex>`: the shader translation chain the game was built with. The shell refuses a different one.
    public var chain: String
    /// `FR` or `FH`.
    public var loader: String
    public var framework: String
    public var frameworkExecutable: String
    public var imageMarker: String
    public var profile: String
    public var shaderMap: String
    public var launcher: String
    /// A path inside a RomFS folder that only this game's data has.
    public var romfsMarker: String
    public var romfsIdentity: String
    public var minOS: String
    public var icon: String?
    public var builtBy: String?
    public var builtAt: String?
    public var bytes: Int?

    public static let supportedSchema = 1

    enum CodingKeys: String, CodingKey {
        case schema, name, modules, chain, loader, framework, profile, launcher, icon, bytes
        case titleID = "title_id", displayVersion = "display_version", packageVersion = "package_version"
        case nroCount = "nro_count", frameworkExecutable = "framework_executable", imageMarker = "image_marker"
        case shaderMap = "shader_map", romfsMarker = "romfs_marker", romfsIdentity = "romfs_identity", minOS = "min_os"
        case builtBy = "built_by", builtAt = "built_at"
    }

    /// Decodes and validates. A problem carries a readable reason for the broken state.
    public static func parse(_ data: Data) throws(GameProblem) -> GameManifest {
        let manifest: GameManifest
        do { manifest = try JSONDecoder().decode(GameManifest.self, from: data) }
        catch { throw describe(error, file: "game.manifest.json", what: hostText("The game's manifest")) }
        guard manifest.schema == supportedSchema else {
            throw GameProblem(reason: hostText("Manifest not supported"),
                              detail: hostText("game.manifest.json has schema \(manifest.schema), this app reads schema \(supportedSchema)."))
        }
        guard isTitleID(manifest.titleID) else {
            throw GameProblem(reason: hostText("Manifest damaged"), detail: hostText("title_id \"\(manifest.titleID)\" is not 16 hex digits."))
        }
        guard !manifest.modules.isEmpty else {
            throw GameProblem(reason: hostText("Manifest damaged"), detail: hostText("The manifest lists no modules."))
        }
        guard manifest.chain.hasPrefix("b-"), manifest.chain.count > 2, manifest.chain.dropFirst(2).allSatisfy(\.isHexDigit) else {
            throw GameProblem(reason: hostText("Manifest damaged"), detail: hostText("chain \"\(manifest.chain)\" is not of the form b-<hex>."))
        }
        guard ["FR", "FH"].contains(manifest.loader) else {
            throw GameProblem(reason: hostText("Manifest damaged"), detail: hostText("loader \"\(manifest.loader)\" is neither FR nor FH."))
        }
        guard manifest.framework.hasSuffix(".framework"), !manifest.framework.contains("/") else {
            throw GameProblem(reason: hostText("Manifest damaged"), detail: hostText("framework \"\(manifest.framework)\" is not a .framework name."))
        }
        return manifest
    }

    /// The minimum OS as a version, nil when it is not numeric.
    var minOSVersion: OperatingSystemVersion? { parseVersion(minOS) }
}

func isTitleID(_ text: String) -> Bool {
    text.count == 16 && text.allSatisfy { $0.isNumber || ("A"..."F").contains($0) }
}

func parseVersion(_ text: String) -> OperatingSystemVersion? {
    let parts = text.split(separator: ".").map { Int($0) }
    guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
    let n = parts.compactMap { $0 }
    return OperatingSystemVersion(majorVersion: n[0], minorVersion: n.count > 1 ? n[1] : 0, patchVersion: n.count > 2 ? n[2] : 0)
}

func isVersion(_ a: OperatingSystemVersion, atLeast b: OperatingSystemVersion) -> Bool {
    (a.majorVersion, a.minorVersion, a.patchVersion) >= (b.majorVersion, b.minorVersion, b.patchVersion)
}

/// A decoding error as one readable sentence.
func describe(_ error: Error, file: String, what: String) -> GameProblem {
    let short = hostText("Game files damaged")
    guard let e = error as? DecodingError else { return GameProblem(reason: short, detail: "\(file): \(error.localizedDescription)") }
    func path(_ c: [CodingKey]) -> String { c.map { $0.stringValue }.joined(separator: ".") }
    switch e {
    case .keyNotFound(let key, let c):
        let at = c.codingPath.isEmpty ? "" : " (in \(path(c.codingPath)))"
        return GameProblem(reason: short, detail: hostText("\(file) has no \"\(key.stringValue)\"\(at)."))
    case .typeMismatch(_, let c), .valueNotFound(_, let c):
        return GameProblem(reason: short, detail: hostText("\(file) has a wrong or missing value at \"\(path(c.codingPath))\"."))
    case .dataCorrupted:
        return GameProblem(reason: short, detail: hostText("\(file) is not valid JSON."))
    @unknown default:
        return GameProblem(reason: short, detail: file)
    }
}
