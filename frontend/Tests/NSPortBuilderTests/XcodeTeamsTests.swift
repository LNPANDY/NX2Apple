import XCTest
@testable import NSPortBuilder

/// #87: the signing teams of the Apple IDs signed in to Xcode, read from Xcode's preferences (sample plists, not this
/// Mac's), merged with the teams of development certificates.
final class XcodeTeamsTests: XCTestCase {
    private func plist(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """.utf8)
    }

    private func team(_ id: String, _ name: String, free: Bool? = nil, type: String? = nil) -> String {
        "<dict>" + (free.map { "<key>isFreeProvisioningTeam</key><\($0)/>" } ?? "") + "<key>teamID</key><string>\(id)</string>"
            + "<key>teamName</key><string>\(name)</string>" + (type.map { "<key>teamType</key><string>\($0)</string>" } ?? "") + "</dict>"
    }

    func testTheCurrentShapeAccountIdentifierToTeams() {
        let data = plist("""
        <key>IDEProvisioningTeamByIdentifier</key><dict>
          <key>0A681446-AAAA</key><array>\(team("ABCDE12345", "Jo Doe", free: false, type: "Individual"))</array>
          <key>5B7C0000-BBBB</key><array>\(team("FGHIJ67890", "Jo Doe", free: true, type: "Personal Team"))\(team("KLMNO11111", "Studio Ltd", free: false, type: "Company/Organization"))</array>
        </dict>
        <key>IDEProvisioningTeamManagerLastSelectedTeamID</key><string>ABCDE12345</string>
        """)
        let teams = DeviceTools.xcodeTeams(fromPlist: data)
        XCTAssertEqual(Set(teams.map(\.id)), ["ABCDE12345", "FGHIJ67890", "KLMNO11111"])
        XCTAssertEqual(teams.first { $0.id == "ABCDE12345" }, XcodeTeam(id: "ABCDE12345", name: "Jo Doe", free: false))
        XCTAssertEqual(teams.first { $0.id == "FGHIJ67890" }?.free, true)
        XCTAssertEqual(teams.first { $0.id == "KLMNO11111" }?.name, "Studio Ltd")
    }

    func testTheOlderShapeAndAFreeTeamWithoutTheFlag() {
        let data = plist("""
        <key>IDEProvisioningTeams</key><dict>
          <key>jo@example.invalid</key><array>\(team("ABCDE12345", "Jo Doe (Personal Team)", type: "Free"))</array>
        </dict>
        """)
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: data), [XcodeTeam(id: "ABCDE12345", name: "Jo Doe (Personal Team)", free: true)])
        let flat = plist("<key>IDEProvisioningTeams</key><array>\(team("ABCDE12345", "Jo Doe"))</array>")
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: flat), [XcodeTeam(id: "ABCDE12345", name: "Jo Doe", free: false)], "a plain array, no flag: not free")
    }

    func testMissingKeysAndOtherShapesGiveNoTeams() {
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: plist("<key>Other</key><string>x</string>")), [])
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: plist("<key>IDEProvisioningTeamByIdentifier</key><dict/>")), [])
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: plist("<key>IDEProvisioningTeamByIdentifier</key><string>unexpected</string>")), [])
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: plist("<key>IDEProvisioningTeamByIdentifier</key><dict><key>A</key><array><string>x</string></array></dict>")), [])
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: Data("not a plist".utf8)), [])
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: Data()), [])
        // a dictionary whose team ID is not a team ID (a stray key) is not a team; a team of another key in the file is not read
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: plist("<key>IDEProvisioningTeamByIdentifier</key><dict><key>A</key><array>\(team("short", "x"))</array></dict>")), [])
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: plist("<key>Elsewhere</key><array>\(team("ABCDE12345", "x"))</array>")), [])
    }

    func testTheSameTeamUnderTwoAccountsIsListedOnce() {
        let data = plist("""
        <key>IDEProvisioningTeamByIdentifier</key><dict>
          <key>A</key><array>\(team("ABCDE12345", "Studio Ltd", free: false))</array>
          <key>B</key><array>\(team("ABCDE12345", "Studio Ltd", free: false))</array>
        </dict>
        """)
        XCTAssertEqual(DeviceTools.xcodeTeams(fromPlist: data).count, 1)
    }

    func testTheUnionOfAccountsAndCertificates() {
        let certificates = [SigningTeam(id: "ABCDE12345", identity: "Apple Development: Jo Doe (XXXXXXXXXX)"),
                            SigningTeam(id: "ABCDE12345", identity: "Apple Development: Jo Doe (YYYYYYYYYY)"),
                            SigningTeam(id: "CERTONLY12", identity: "iPhone Developer: Lee Roe (ZZZZZZZZZZ)")]
        let xcode = [XcodeTeam(id: "FGHIJ67890", name: "Jo Doe", free: true), XcodeTeam(id: "ABCDE12345", name: "Studio Ltd", free: false)]
        let merged = DeviceTools.merge(certificates: certificates, xcode: xcode)
        XCTAssertEqual(merged.map(\.id), ["ABCDE12345", "CERTONLY12", "FGHIJ67890"], "certificates first, one entry per team ID")
        XCTAssertEqual(merged[0].name, "Studio Ltd")
        XCTAssertTrue(merged[0].hasCertificate)
        XCTAssertEqual(merged[0].identity, "Apple Development: Jo Doe (XXXXXXXXXX)")
        XCTAssertTrue(merged[1].hasCertificate)
        XCTAssertFalse(merged[2].hasCertificate, "signed in to Xcode, no certificate yet: Xcode makes it at the first install")
        XCTAssertTrue(merged[2].personal)
        XCTAssertEqual(DeviceTools.merge(certificates: [], xcode: []), [], "neither an account nor a certificate")
    }

    func testTheMenuLabels() {
        XCTAssertEqual(SigningTeam(id: "FGHIJ67890", identity: "", name: "Jo Doe", personal: true).label(personalTeam: "Personal team"),
                       "Jo Doe (Personal team) · FGHIJ67890")
        XCTAssertEqual(SigningTeam(id: "ABCDE12345", identity: "", name: "Studio Ltd").label(personalTeam: "Personal team"), "Studio Ltd · ABCDE12345")
        XCTAssertEqual(SigningTeam(id: "TEAM123456", identity: "Apple Development: Jo Doe (ABCDE12345)").label(personalTeam: "Personal team"),
                       "Jo Doe · TEAM123456", "a team only a certificate knows keeps the holder's name from it")
        XCTAssertEqual(SigningTeam(id: "TEAM123456", identity: "").label(personalTeam: "Personal team"), "TEAM123456")
    }

    func testTheNoTeamMessageNamesTheRealCause() {
        for lang in [Lang.en, .zh] {
            let m = BuildModel(); m.lang = lang
            XCTAssertFalse(m.t("dev.noTeam").isEmpty)
            XCTAssertNotEqual(m.t("dev.teamNoCert"), "dev.teamNoCert")
            XCTAssertNotEqual(m.t("dev.personalTeam"), "dev.personalTeam")
        }
        let m = BuildModel(); m.lang = .en
        XCTAssertTrue(m.t("dev.noTeam").contains("Settings → Apple Accounts"))
        XCTAssertTrue(m.t("dev.noTeam").contains("no development certificate"))
        XCTAssertTrue(m.t("dev.noTeam").contains("Download Manual Profiles"))
        XCTAssertFalse(m.t("dev.noTeam").contains("(null)"))
        XCTAssertTrue(m.t("dev.teamNoCert").contains("first install"))
    }
}
