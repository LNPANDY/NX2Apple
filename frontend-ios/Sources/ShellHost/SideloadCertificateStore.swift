import CryptoKit
import Foundation
import Security
import ShellUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

// MARK: - Minimal ASN.1 DER reader & writer (RFC 5280 / X.690 / RFC 5652)

enum ASN1DER {
    struct Element {
        let tag: UInt8
        let fullRange: Range<Int>
        let valueRange: Range<Int>

        func fullData(in bytes: Data) -> Data {
            bytes.subdata(in: fullRange)
        }

        func valueData(in bytes: Data) -> Data {
            bytes.subdata(in: valueRange)
        }
    }

    static func readElement(in data: Data, at offset: Int) -> Element? {
        let start = data.startIndex
        let end = data.endIndex
        guard offset >= start, offset < end else { return nil }
        let tag = data[offset]
        let lenStart = offset + 1
        guard lenStart < end else { return nil }
        let firstLen = data[lenStart]
        let length: Int
        let valueStart: Int
        if firstLen < 0x80 {
            length = Int(firstLen)
            valueStart = lenStart + 1
        } else {
            let count = Int(firstLen & 0x7f)
            // Reject indefinite length (0x80) and > 4 byte lengths to guard against crafted inputs.
            guard count >= 1, count <= 4, lenStart + count < end else { return nil }
            var accum: UInt64 = 0
            for i in 1...count {
                accum = (accum << 8) | UInt64(data[lenStart + i])
            }
            guard accum <= UInt64(Int.max) else { return nil }
            length = Int(accum)
            valueStart = lenStart + 1 + count
        }
        guard length >= 0, valueStart <= end, length <= end - valueStart else { return nil }
        let valueEnd = valueStart + length
        return Element(tag: tag, fullRange: offset..<valueEnd, valueRange: valueStart..<valueEnd)
    }

    static func children(of element: Element, in data: Data) -> [Element]? {
        var result: [Element] = []
        var cursor = element.valueRange.lowerBound
        while cursor < element.valueRange.upperBound {
            guard let child = readElement(in: data, at: cursor),
                  child.fullRange.upperBound <= element.valueRange.upperBound else {
                return nil
            }
            result.append(child)
            cursor = child.fullRange.upperBound
        }
        return result
    }

    static func encodeLength(_ length: Int) -> Data {
        precondition(length >= 0)
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.append(UInt8(remaining & 0xff))
            remaining >>= 8
        }
        bytes.reverse()
        var out = Data([0x80 | UInt8(bytes.count)])
        out.append(contentsOf: bytes)
        return out
    }

    static func tlv(tag: UInt8, content: Data) -> Data {
        var out = Data([tag])
        out.append(encodeLength(content.count))
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data {
        var body = Data()
        for item in items { body.append(item) }
        return tlv(tag: 0x30, content: body)
    }

    static func set(_ items: [Data], sortByDER: Bool = true) -> Data {
        let ordered = sortByDER ? items.sorted { $0.lexicographicallyPrecedes($1) } : items
        var body = Data()
        for item in ordered { body.append(item) }
        return tlv(tag: 0x31, content: body)
    }

    static func integer(_ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.append(UInt8(v & 0xff))
            v >>= 8
        } while v > 0
        bytes.reverse()
        if let first = bytes.first, (first & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        return tlv(tag: 0x02, content: Data(bytes))
    }

    static func octetString(_ data: Data) -> Data {
        tlv(tag: 0x04, content: data)
    }

    static func null() -> Data {
        Data([0x05, 0x00])
    }

    static func oid(_ arcs: [UInt32]) -> Data {
        precondition(arcs.count >= 2 && arcs[0] <= 2 && arcs[1] < 40)
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            if arc == 0 {
                body.append(0)
                continue
            }
            var chunks: [UInt8] = []
            var v = arc
            while v > 0 {
                chunks.append(UInt8(v & 0x7f))
                v >>= 7
            }
            chunks.reverse()
            for i in 0..<(chunks.count - 1) {
                chunks[i] |= 0x80
            }
            body.append(contentsOf: chunks)
        }
        return tlv(tag: 0x06, content: body)
    }

    static func utcTime(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents(in: utc, from: date)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        if year >= 1950 && year <= 2049 {
            let text = String(format: "%02d%02d%02d%02d%02d%02dZ", year % 100, month, day, hour, minute, second)
            return tlv(tag: 0x17, content: Data(text.utf8))
        }
        let text = String(format: "%04d%02d%02d%02d%02d%02dZ", year, month, day, hour, minute, second)
        return tlv(tag: 0x18, content: Data(text.utf8))
    }

    static func contextExplicit(_ tagNumber: UInt8, content: Data) -> Data {
        tlv(tag: 0xA0 | (tagNumber & 0x1f), content: content)
    }

    static func contextImplicitConstructed(_ tagNumber: UInt8, items: [Data]) -> Data {
        var body = Data()
        for item in items { body.append(item) }
        return tlv(tag: 0xA0 | (tagNumber & 0x1f), content: body)
    }
}

// MARK: - X.509 Certificate Metadata Parser

struct X509CertificateInfo: Equatable, Sendable {
    var commonName: String
    var teamID: String
    var notBefore: Date?
    var notAfter: Date?
    var issuerRawTLV: Data
    var subjectRawTLV: Data
    var serialNumberRawTLV: Data
    var fingerprintHex: String
}

enum X509CertificateParser {
    private static let oidCommonName = Data([0x55, 0x04, 0x03]) // 2.5.4.3
    private static let oidOrgUnit = Data([0x55, 0x04, 0x0b])    // 2.5.4.11

    static func parse(der: Data) -> X509CertificateInfo? {
        guard let root = ASN1DER.readElement(in: der, at: der.startIndex),
              root.tag == 0x30,
              let certChildren = ASN1DER.children(of: root, in: der),
              certChildren.count >= 3 else {
            return nil
        }
        let tbs = certChildren[0]
        guard tbs.tag == 0x30,
              let tbsFields = ASN1DER.children(of: tbs, in: der) else {
            return nil
        }
        var idx = 0
        if idx < tbsFields.count && tbsFields[idx].tag == 0xA0 {
            idx += 1 // optional [0] EXPLICIT version
        }
        // TBSCertificate order: serialNumber, signature, issuer, validity, subject
        guard tbsFields.count >= idx + 5 else { return nil }
        let serialEl = tbsFields[idx]
        let issuerEl = tbsFields[idx + 2]
        let validityEl = tbsFields[idx + 3]
        let subjectEl = tbsFields[idx + 4]

        guard serialEl.tag == 0x02,
              issuerEl.tag == 0x30,
              validityEl.tag == 0x30,
              subjectEl.tag == 0x30 else {
            return nil
        }

        let (notBefore, notAfter) = parseValidity(validityEl, in: der)
        let (commonName, teamID) = parseSubject(subjectEl, in: der)
        let digest = SHA256.hash(data: der)
        let fingerprintHex = digest.map { String(format: "%02x", $0) }.joined()

        return X509CertificateInfo(
            commonName: commonName,
            teamID: teamID,
            notBefore: notBefore,
            notAfter: notAfter,
            issuerRawTLV: issuerEl.fullData(in: der),
            subjectRawTLV: subjectEl.fullData(in: der),
            serialNumberRawTLV: serialEl.fullData(in: der),
            fingerprintHex: fingerprintHex
        )
    }

    private static func parseValidity(_ validity: ASN1DER.Element, in data: Data) -> (Date?, Date?) {
        guard let fields = ASN1DER.children(of: validity, in: data), fields.count >= 2 else {
            return (nil, nil)
        }
        return (parseTime(fields[0], in: data), parseTime(fields[1], in: data))
    }

    private static func parseTime(_ el: ASN1DER.Element, in data: Data) -> Date? {
        guard el.tag == 0x17 || el.tag == 0x18,
              let raw = String(data: el.valueData(in: data), encoding: .ascii),
              raw.hasSuffix("Z") else {
            return nil
        }
        let digits = String(raw.dropLast())
        let year: Int
        let restStart: String.Index
        if el.tag == 0x17 {
            guard digits.count == 12, let yy = Int(digits.prefix(2)) else { return nil }
            year = yy >= 50 ? 1900 + yy : 2000 + yy
            restStart = digits.index(digits.startIndex, offsetBy: 2)
        } else {
            guard digits.count == 14, let yyyy = Int(digits.prefix(4)) else { return nil }
            year = yyyy
            restStart = digits.index(digits.startIndex, offsetBy: 4)
        }
        let tail = String(digits[restStart...])
        guard tail.count == 10,
              let month = Int(tail.prefix(2)),
              let day = Int(tail.dropFirst(2).prefix(2)),
              let hour = Int(tail.dropFirst(4).prefix(2)),
              let minute = Int(tail.dropFirst(6).prefix(2)),
              let second = Int(tail.dropFirst(8).prefix(2)) else {
            return nil
        }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return comps.date
    }

    private static func parseSubject(_ subject: ASN1DER.Element, in data: Data) -> (commonName: String, teamID: String) {
        guard let rdns = ASN1DER.children(of: subject, in: data) else { return ("", "") }
        var commonName = ""
        var orgUnits: [String] = []
        for rdn in rdns where rdn.tag == 0x31 {
            guard let atvs = ASN1DER.children(of: rdn, in: data) else { continue }
            for atv in atvs where atv.tag == 0x30 {
                guard let pair = ASN1DER.children(of: atv, in: data), pair.count >= 2,
                      pair[0].tag == 0x06 else { continue }
                let oidBytes = pair[0].valueData(in: data)
                guard let text = decodeDirectoryString(pair[1], in: data), !text.isEmpty else { continue }
                if oidBytes == oidCommonName, commonName.isEmpty {
                    commonName = text
                } else if oidBytes == oidOrgUnit {
                    orgUnits.append(text)
                }
            }
        }
        let preferredTeam = orgUnits.first { isAppleTeamID($0) } ?? orgUnits.first ?? ""
        return (commonName, preferredTeam)
    }

    private static func isAppleTeamID(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
        }
    }

    private static func decodeDirectoryString(_ el: ASN1DER.Element, in data: Data) -> String? {
        let bytes = el.valueData(in: data)
        switch el.tag {
        case 0x0c, 0x13, 0x16, 0x14:
            return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
        case 0x1e:
            return String(data: bytes, encoding: .utf16BigEndian)
        default:
            return String(data: bytes, encoding: .utf8)
        }
    }
}

// MARK: - Keychain / Testable Storage Backing

/// Raw credential storage backend for the sideload `.p12` certificate.
/// Production uses iOS Keychain; tests inject `InMemoryCertBacking` so no entitlements are needed.
public protocol SideloadCertBacking: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public struct KeychainCertBacking: SideloadCertBacking {
    public static let defaultService = "org.nxnative.shell.sideload-cert"
    public static let defaultAccount = "default"

    public let service: String
    public let account: String

    public init(service: String = Self.defaultService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SideloadCertificateError.storageFailed(status)
        }
        return result as? Data
    }

    public func save(_ data: Data) throws {
        // Delete any existing item first so attributes (including accessibility) stay exact.
        let delStatus = SecItemDelete(baseQuery() as CFDictionary)
        if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
            throw SideloadCertificateError.storageFailed(delStatus)
        }
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SideloadCertificateError.storageFailed(addStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SideloadCertificateError.storageFailed(status)
        }
    }
}

public final class InMemoryCertBacking: SideloadCertBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var payload: Data?

    public init(initialData: Data? = nil) {
        self.payload = initialData
    }

    public func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    public func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        payload = data
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        payload = nil
    }
}

// MARK: - Certificate Store & PKCS#12 Import

public enum SideloadCertificateError: LocalizedError, Equatable, Sendable {
    case emptyFile
    case fileTooLarge
    case wrongPassword
    case invalidFormat(OSStatus)
    case missingIdentity
    case certificateUnreadable
    case notConfigured
    case storageFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return hostText("The selected certificate file is empty.")
        case .fileTooLarge:
            return hostText("The selected certificate file is too large.")
        case .wrongPassword:
            return hostText("The certificate password is incorrect.")
        case .invalidFormat:
            return hostText("The selected file is not a valid .p12 certificate.")
        case .missingIdentity:
            return hostText("The certificate file does not contain a signing identity and private key.")
        case .certificateUnreadable:
            return hostText("The certificate details could not be read.")
        case .notConfigured:
            return hostText("No sideload certificate is imported.")
        case .storageFailed:
            return hostText("The certificate could not be saved securely to Keychain.")
        }
    }
}

/// Live signing identity extracted from a validated `.p12`.
/// On macOS unit tests, owns an ephemeral temporary keychain that is deleted on `deinit` so tests never pollute the login keychain.
public final class SideloadSigningIdentity: @unchecked Sendable {
    public let identity: SecIdentity?
    public let privateKey: SecKey
    public let leafCertificateDER: Data
    public let chainCertificatesDER: [Data]
    let leafInfo: X509CertificateInfo
    public let summary: SideloadCertificateSummary

    #if os(macOS)
    fileprivate static let keychainLock = NSLock()
    private let ephemeralKeychain: SecKeychain?
    private let ephemeralKeychainPath: String?
    #endif

    #if os(macOS)
    init(identity: SecIdentity?, privateKey: SecKey, leafCertificateDER: Data, chainCertificatesDER: [Data],
         leafInfo: X509CertificateInfo, summary: SideloadCertificateSummary,
         ephemeralKeychain: SecKeychain?, ephemeralKeychainPath: String?) {
        self.identity = identity
        self.privateKey = privateKey
        self.leafCertificateDER = leafCertificateDER
        self.chainCertificatesDER = chainCertificatesDER
        self.leafInfo = leafInfo
        self.summary = summary
        self.ephemeralKeychain = ephemeralKeychain
        self.ephemeralKeychainPath = ephemeralKeychainPath
    }

    deinit {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }
        if let ephemeralKeychain {
            SecKeychainDelete(ephemeralKeychain)
        }
        if let ephemeralKeychainPath {
            try? FileManager.default.removeItem(atPath: ephemeralKeychainPath)
        }
    }
    #else
    init(identity: SecIdentity?, privateKey: SecKey, leafCertificateDER: Data, chainCertificatesDER: [Data],
         leafInfo: X509CertificateInfo, summary: SideloadCertificateSummary) {
        self.identity = identity
        self.privateKey = privateKey
        self.leafCertificateDER = leafCertificateDER
        self.chainCertificatesDER = chainCertificatesDER
        self.leafInfo = leafInfo
        self.summary = summary
    }
    #endif
}

public final class SideloadCertificateStore: Sendable {
    public static let maxFileBytes = 1024 * 1024

    private struct StoredCredential: Codable {
        var version: Int = 1
        var p12Data: Data
        var password: String
    }

    private let backing: any SideloadCertBacking
    private let now: @Sendable () -> Date

    public init(backing: any SideloadCertBacking = KeychainCertBacking(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.backing = backing
        self.now = now
    }

    /// Validates `p12Data` and `password`, then stores them securely in `backing` (never plain files or UserDefaults).
    @discardableResult
    public func importPKCS12(data: Data, password: String) throws -> SideloadCertificateSummary {
        let parsed = try Self.parseIdentity(p12Data: data, password: password, now: now())
        let encoded = try JSONEncoder().encode(StoredCredential(p12Data: data, password: password))
        try backing.save(encoded)
        return parsed.summary
    }

    public func loadSummary() -> SideloadCertificateSummary? {
        guard let identity = try? loadIdentity() else { return nil }
        return identity.summary
    }

    public func loadIdentity() throws -> SideloadSigningIdentity {
        guard let raw = try backing.load() else {
            throw SideloadCertificateError.notConfigured
        }
        let decoded: StoredCredential
        do {
            decoded = try JSONDecoder().decode(StoredCredential.self, from: raw)
        } catch {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
        return try Self.parseIdentity(p12Data: decoded.p12Data, password: decoded.password, now: now())
    }

    public var hasCertificate: Bool {
        (try? backing.load()) != nil
    }

    public func remove() throws {
        try backing.delete()
    }

    /// Parses and validates a `.p12`/`.pfx` blob without persisting it.
    public static func parseIdentity(p12Data: Data, password: String, now: Date = Date()) throws -> SideloadSigningIdentity {
        guard !p12Data.isEmpty else { throw SideloadCertificateError.emptyFile }
        guard p12Data.count <= maxFileBytes else { throw SideloadCertificateError.fileTooLarge }

        var options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
        ]

        #if os(macOS)
        SideloadSigningIdentity.keychainLock.lock()
        let kcPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("nx2apple-p12-\(UUID().uuidString).keychain-db").path
        var ephemeralKC: SecKeychain?
        let kcPassword = UUID().uuidString
        let kcStatus = kcPassword.withCString { cPass in
            SecKeychainCreate(kcPath, UInt32(strlen(cPass)), cPass, false, nil, &ephemeralKC)
        }
        if kcStatus == errSecSuccess, let ephemeralKC {
            options[kSecImportExportKeychain as String] = ephemeralKC
        }
        func cleanupEphemeralKeychain() {
            if let ephemeralKC {
                SecKeychainDelete(ephemeralKC)
            }
            try? FileManager.default.removeItem(atPath: kcPath)
        }
        #endif

        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        #if os(macOS)
        if status != errSecSuccess {
            cleanupEphemeralKeychain()
        }
        SideloadSigningIdentity.keychainLock.unlock()
        #endif
        guard status == errSecSuccess else {
            // Fall back to the RFC 7292 parser for valid `.p12` variants rejected by iOS `SecPKCS12Import`
            // (such as SideStore passwordless MAC-less `keyBag` exports, `SecItemExport` 40-bit RC2 cert bags,
            // and OpenSSL 3 PBES2 empty-password containers).
            do {
                return try PKCS12FallbackParser.parseIdentity(p12Data: p12Data, password: password, now: now)
            } catch let fallbackError as SideloadCertificateError {
                if case .invalidFormat = fallbackError, status == errSecAuthFailed {
                    throw SideloadCertificateError.wrongPassword
                }
                throw fallbackError
            }
        }

        guard let itemList = rawItems as? [[String: Any]],
              let chosen = itemList.first(where: { $0[kSecImportItemIdentity as String] != nil }),
              let rawIdentity = chosen[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            #if os(macOS)
            SideloadSigningIdentity.keychainLock.lock()
            cleanupEphemeralKeychain()
            SideloadSigningIdentity.keychainLock.unlock()
            #endif
            throw SideloadCertificateError.missingIdentity
        }
        let identity = rawIdentity as! SecIdentity

        var certRef: SecCertificate?
        var keyRef: SecKey?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let leafCert = certRef,
              SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess,
              let privateKey = keyRef else {
            #if os(macOS)
            SideloadSigningIdentity.keychainLock.lock()
            cleanupEphemeralKeychain()
            SideloadSigningIdentity.keychainLock.unlock()
            #endif
            throw SideloadCertificateError.missingIdentity
        }

        let leafDER = SecCertificateCopyData(leafCert) as Data
        guard let leafInfo = X509CertificateParser.parse(der: leafDER) else {
            #if os(macOS)
            SideloadSigningIdentity.keychainLock.lock()
            cleanupEphemeralKeychain()
            SideloadSigningIdentity.keychainLock.unlock()
            #endif
            throw SideloadCertificateError.certificateUnreadable
        }

        var chainDER: [Data] = []
        if let rawChain = chosen[kSecImportItemCertChain as String] as? [Any] {
            for entry in rawChain {
                let cf = entry as CFTypeRef
                if CFGetTypeID(cf) == SecCertificateGetTypeID() {
                    let der = SecCertificateCopyData(cf as! SecCertificate) as Data
                    if der != leafDER {
                        chainDER.append(der)
                    }
                }
            }
        }

        let displayName = leafInfo.commonName.isEmpty
            ? ((SecCertificateCopySubjectSummary(leafCert) as String?) ?? "")
            : leafInfo.commonName
        let isExpired = leafInfo.notAfter.map { $0 <= now } ?? false
        let summary = SideloadCertificateSummary(
            commonName: displayName,
            teamID: leafInfo.teamID,
            expiresAt: leafInfo.notAfter,
            isExpired: isExpired,
            fingerprintHex: leafInfo.fingerprintHex
        )

        #if os(macOS)
        return SideloadSigningIdentity(
            identity: identity,
            privateKey: privateKey,
            leafCertificateDER: leafDER,
            chainCertificatesDER: chainDER,
            leafInfo: leafInfo,
            summary: summary,
            ephemeralKeychain: ephemeralKC,
            ephemeralKeychainPath: kcPath
        )
        #else
        return SideloadSigningIdentity(
            identity: identity,
            privateKey: privateKey,
            leafCertificateDER: leafDER,
            chainCertificatesDER: chainDER,
            leafInfo: leafInfo,
            summary: summary
        )
        #endif
    }
}

// MARK: - Certificate File Picker Protocol

public enum CertificatePickOutcome: Sendable {
    case picked(data: Data, fileName: String)
    case cancelled
    case unavailable
    case unreadable
}

public protocol SideloadCertificatePicker: Sendable {
    @MainActor func pickCertificateOutcome() async -> CertificatePickOutcome
}

public struct NoSideloadCertificatePicker: SideloadCertificatePicker {
    public init() {}
    @MainActor public func pickCertificateOutcome() async -> CertificatePickOutcome { .cancelled }
}

#if canImport(UIKit)
public struct DocumentCertificatePicker: SideloadCertificatePicker {
    public init() {}

    private nonisolated static func makeAnswer(_ continuation: CheckedContinuation<URL?, Never>) -> FolderPickAnswer<URL> {
        FolderPickAnswer { continuation.resume(returning: $0) }
    }

    @MainActor public func pickCertificateOutcome() async -> CertificatePickOutcome {
        guard let presenter = DocumentFolderPicker.topViewController() else { return .unavailable }
        var types: [UTType] = [.pkcs12]
        if let pfx = UTType(filenameExtension: "pfx"), !types.contains(pfx) {
            types.append(pfx)
        }
        let copiedURL: URL? = await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.allowsMultipleSelection = false
            let delegate = Delegate(answer: Self.makeAnswer(continuation))
            picker.delegate = delegate
            picker.presentationController?.delegate = delegate
            objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
        guard let copiedURL else { return .cancelled }
        defer { try? FileManager.default.removeItem(at: copiedURL) }
        let fileName = copiedURL.lastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: copiedURL.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size >= 0, size <= Int64(SideloadCertificateStore.maxFileBytes) else {
            return .unreadable
        }
        guard let data = try? Data(contentsOf: copiedURL) else { return .unreadable }
        return .picked(data: data, fileName: fileName)
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        nonisolated(unsafe) static var key = 0
        private let answer: FolderPickAnswer<URL>
        init(answer: FolderPickAnswer<URL>) { self.answer = answer }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DocumentPickerDismissWaiter.finishAfterDismiss(controller: controller, value: urls.first, answer: answer)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
            DocumentPickerDismissWaiter.finishAfterDismiss(controller: controller, value: url, answer: answer)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentPickerDismissWaiter.finishAfterDismiss(controller: controller, value: nil, answer: answer)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { answer.finish(nil) }
    }
}
#endif
