import Foundation

/// An iPhone or iPad paired with this Mac (Xcode's `devicectl`), a target for installing a build directly.
struct AppleDevice: Identifiable, Equatable {
    let id: String          // the UDID
    let name: String
    let model: String
    let os: String
    let reachable: Bool     // connected now, by cable or the local network
}

/// A team the launcher can sign for: from a development certificate in the keychain, from an account signed in to
/// Xcode, or both (#87: signing in to Xcode alone creates no certificate; `xcodebuild -allowProvisioningUpdates` makes
/// it at the first install).
struct SigningTeam: Identifiable, Equatable {
    let id: String          // the team ID: the certificate's organizational unit, not the code in its name
    let identity: String    // "Apple Development: Name (ABCDE12345)"; empty when only an Xcode account knows the team
    var name: String = ""   // the team's name in Xcode; empty when only a certificate knows the team
    var personal = false    // a free Apple ID's "Personal team"

    var hasCertificate: Bool { !identity.isEmpty }

    /// The name in the team menu: the team name (or the certificate holder's), "Personal team" for a free one, and the ID.
    func label(personalTeam: String) -> String {
        var holder = name
        if holder.isEmpty {
            holder = identity.replacingOccurrences(of: #"^(Apple Development|iPhone Developer): "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" \([A-Z0-9]+\)$"#, with: "", options: .regularExpression)
        }
        return (holder.isEmpty ? id : holder + (personal ? " (" + personalTeam + ")" : "") + " · " + id)
    }
}

/// A team of an Apple ID signed in to Xcode, as Xcode's preferences list it.
struct XcodeTeam: Equatable {
    let id: String
    let name: String
    let free: Bool
}

/// Xcode's own tools for devices and signing: `xcrun devicectl` and `security`. Nothing here signs or installs;
/// it only reads what is paired and what can sign.
enum DeviceTools {
    /// The paired physical iPhones and iPads, reachable ones first.
    /// `timeout` ends a listing that hangs (the Saves sheet asks with one), as no devices.
    static func devices(xcrun: String = "/usr/bin/xcrun", timeout: TimeInterval? = nil) -> [AppleDevice] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard run(xcrun, ["devicectl", "list", "devices", "--json-output", file.path], timeout: timeout) != nil,
              let data = try? Data(contentsOf: file) else { return [] }
        return parseDevices(data)
    }

    static func parseDevices(_ data: Data) -> [AppleDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let list = result["devices"] as? [[String: Any]] else { return [] }
        let devices: [AppleDevice] = list.compactMap { d in
            let hardware = d["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = d["deviceProperties"] as? [String: Any] ?? [:]
            let connection = d["connectionProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String == "physical", hardware["platform"] as? String == "iOS",
                  connection["pairingState"] as? String == "paired",
                  let udid = hardware["udid"] as? String, !udid.isEmpty else { return nil }
            return AppleDevice(id: udid, name: properties["name"] as? String ?? udid,
                               model: hardware["marketingName"] as? String ?? "",
                               os: properties["osVersionNumber"] as? String ?? "",
                               reachable: connection["transportType"] is String)
        }
        return devices.sorted { ($0.reachable ? 0 : 1, $0.name) < ($1.reachable ? 0 : 1, $1.name) }
    }

    /// Every team the launcher can offer: the teams of the Apple IDs signed in to Xcode plus the teams of development
    /// certificates in the keychain, one entry per team ID. A team with a certificate comes first (it can sign at once).
    static func teams() -> [SigningTeam] {
        merge(certificates: certificateTeams(), xcode: xcodeTeams())
    }

    /// Pure: union by team ID. The certificate gives the identity, Xcode gives the team's name and whether it is a free one.
    static func merge(certificates: [SigningTeam], xcode: [XcodeTeam]) -> [SigningTeam] {
        var result: [SigningTeam] = []
        for c in certificates where !result.contains(where: { $0.id == c.id }) {
            let known = xcode.first { $0.id == c.id }
            result.append(SigningTeam(id: c.id, identity: c.identity, name: known?.name ?? c.name, personal: known?.free ?? c.personal))
        }
        for x in xcode where !result.contains(where: { $0.id == x.id }) {
            result.append(SigningTeam(id: x.id, identity: "", name: x.name, personal: x.free))
        }
        return result
    }

    /// The teams of the accounts signed in to Xcode, from its preferences (read only; nothing of the account but the
    /// teams is looked at).
    static func xcodeTeams() -> [XcodeTeam] {
        guard let plist = run("/usr/bin/defaults", ["export", "com.apple.dt.Xcode", "-"]) else { return [] }
        return xcodeTeams(fromPlist: Data(plist.utf8))
    }

    /// Pure. Xcode keeps the teams under `IDEProvisioningTeamByIdentifier` (current: account identifier -> array of
    /// teams) or `IDEProvisioningTeams` (older); every dictionary below those keys with a team ID is a team. A missing
    /// key, an unreadable plist or another shape gives no teams.
    static func xcodeTeams(fromPlist data: Data) -> [XcodeTeam] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return [] }
        var found: [XcodeTeam] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let id = dict["teamID"] as? String, id.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
                    let type = (dict["teamType"] as? String ?? "").lowercased()
                    let flag = (dict["isFreeProvisioningTeam"] as? NSNumber)?.boolValue ?? false
                    let free = flag || type.contains("free") || type.contains("personal")
                    if !found.contains(where: { $0.id == id }) { found.append(XcodeTeam(id: id, name: dict["teamName"] as? String ?? "", free: free)) }
                } else {
                    for key in dict.keys.sorted() { walk(dict[key]!) }
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] { if let value = root[key] { walk(value) } }
        return found
    }

    /// The development identities that can sign for a device, with their teams (one per team ID).
    static func certificateTeams() -> [SigningTeam] {
        guard let list = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) else { return [] }
        var seen = Set<String>()
        return identities(list).compactMap { identity in
            guard let pem = run("/usr/bin/security", ["find-certificate", "-c", identity, "-p"]),
                  let subject = run("/usr/bin/openssl", ["x509", "-noout", "-subject"], input: pem),
                  let team = team(fromSubject: subject), seen.insert(team).inserted else { return nil }
            return SigningTeam(id: team, identity: identity)
        }
    }

    /// The quoted names of `security find-identity` that sign for devices (development, not distribution).
    static func identities(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { return nil }
            let name = String(line[line.index(after: open)..<close])
            return name.hasPrefix("Apple Development:") || name.hasPrefix("iPhone Developer:") ? name : nil
        }
    }

    /// OU= of a certificate subject, as `openssl x509 -subject` prints it.
    static func team(fromSubject subject: String) -> String? {
        guard let range = subject.range(of: #"OU\s*=\s*([A-Z0-9]{10})"#, options: .regularExpression) else { return nil }
        return subject[range].split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func run(_ tool: String, _ args: [String], input: String? = nil, timeout: TimeInterval? = nil) -> String? {
        let p = Process(), out = Pipe(), inPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return nil }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            }
        }
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)); try? inPipe.fileHandleForWriting.close() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
