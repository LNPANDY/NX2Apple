import CommonCrypto
import CryptoKit
import Foundation
import Security
import ShellUI

/// Standards-compliant RFC 7292 PKCS#12 / PFX fallback reader for `.p12` files that iOS `SecPKCS12Import`
/// rejects despite being valid sideload credentials (for example SideStore passwordless MAC-less `keyBag` exports,
/// `SecItemExport` 40-bit RC2 certificate bags, and OpenSSL 3 PBES2 empty-password containers).
enum PKCS12FallbackParser {
    private static let maxIterations = 2_000_000
    private static let maxNestingDepth = 4
    private static let maxBagsPerContainer = 128

    // ContentInfo & PKCS#12 SafeBag OIDs (raw DER value bytes without 0x06 tag/length)
    private static let oidData = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01]) // 1.2.840.113549.1.7.1
    private static let oidEncryptedData = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x06]) // 1.2.840.113549.1.7.6
    private static let oidKeyBag = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x01]) // 1.2.840.113549.1.12.10.1.1
    private static let oidPKCS8ShroudedKeyBag = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x02]) // .2
    private static let oidCertBag = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x03]) // .3
    private static let oidSafeContentsBag = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x06]) // .6
    private static let oidX509Certificate = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x16, 0x01]) // 1.2.840.113549.1.9.22.1

    // Digest & PRF OIDs
    private static let oidSHA1 = Data([0x2b, 0x0e, 0x03, 0x02, 0x1a]) // 1.3.14.3.2.26
    private static let oidSHA256 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]) // 2.16.840.1.101.3.4.2.1
    private static let oidSHA384 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02]) // .2
    private static let oidSHA512 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03]) // .3
    private static let oidHMACWithSHA1 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x07]) // 1.2.840.113549.2.7
    private static let oidHMACWithSHA256 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09]) // .9
    private static let oidHMACWithSHA384 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x0a]) // .10
    private static let oidHMACWithSHA512 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x0b]) // .11

    // PKCS#12 PBE & PBES2 OIDs
    private static let oidPBEWithSHAAnd3Key3DES = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x03]) // .12.1.3
    private static let oidPBEWithSHAAnd2Key3DES = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x04]) // .12.1.4
    private static let oidPBEWithSHAAnd128BitRC2 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x05]) // .12.1.5
    private static let oidPBEWithSHAAnd40BitRC2 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x06]) // .12.1.6
    private static let oidPBKDF2 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c]) // 1.2.840.113549.1.5.12
    private static let oidPBES2 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d]) // 1.2.840.113549.1.5.13
    private static let oidDESEDE3CBC = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x03, 0x07]) // 1.2.840.113549.3.7
    private static let oidAES128CBC = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02]) // 2.16.840.1.101.3.4.1.2
    private static let oidAES192CBC = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x16]) // .22
    private static let oidAES256CBC = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a]) // .42

    // Public/private key OIDs
    private static let oidRSAEncryption = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]) // 1.2.840.113549.1.1.1
    private static let oidECPublicKey = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]) // 1.2.840.10045.2.1
    private static let oidPrime256v1 = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]) // 1.2.840.10045.3.1.7
    private static let oidSecp384r1 = Data([0x2b, 0x81, 0x04, 0x00, 0x22]) // 1.3.132.0.34

    private enum HashKind {
        case sha1
        case sha256
        case sha384
        case sha512

        var digestLength: Int {
            switch self {
            case .sha1: return 20
            case .sha256: return 32
            case .sha384: return 48
            case .sha512: return 64
            }
        }

        var blockLength: Int {
            switch self {
            case .sha1, .sha256: return 64
            case .sha384, .sha512: return 128
            }
        }

        func digest(_ data: Data) -> Data {
            switch self {
            case .sha1: return Data(Insecure.SHA1.hash(data: data))
            case .sha256: return Data(SHA256.hash(data: data))
            case .sha384: return Data(SHA384.hash(data: data))
            case .sha512: return Data(SHA512.hash(data: data))
            }
        }

        func hmac(key: Data, message: Data) -> Data {
            let symKey = SymmetricKey(data: key)
            switch self {
            case .sha1: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symKey))
            case .sha256: return Data(HMAC<SHA256>.authenticationCode(for: message, using: symKey))
            case .sha384: return Data(HMAC<SHA384>.authenticationCode(for: message, using: symKey))
            case .sha512: return Data(HMAC<SHA512>.authenticationCode(for: message, using: symKey))
            }
        }
    }

    static func parseIdentity(p12Data: Data, password: String, now: Date) throws -> SideloadSigningIdentity {
        guard let pfx = ASN1DER.readElement(in: p12Data, at: p12Data.startIndex),
              pfx.tag == 0x30,
              let pfxFields = ASN1DER.children(of: pfx, in: p12Data),
              pfxFields.count >= 2,
              pfxFields[0].tag == 0x02,
              readNonNegativeInt(pfxFields[0], in: p12Data) == 3 else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        let authSafeEl = pfxFields[1]
        guard authSafeEl.tag == 0x30,
              let authSafeFields = ASN1DER.children(of: authSafeEl, in: p12Data),
              authSafeFields.count >= 2,
              authSafeFields[0].tag == 0x06,
              authSafeFields[0].valueData(in: p12Data) == oidData,
              authSafeFields[1].tag == 0xA0,
              let authSafeExplicit = ASN1DER.children(of: authSafeFields[1], in: p12Data),
              let firstAuthContent = authSafeExplicit.first,
              let authSafeBytes = extractOctetString(firstAuthContent, in: p12Data, depth: 0) else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        var macVerified = false
        if pfxFields.count >= 3 {
            let macEl = pfxFields[2]
            guard macEl.tag == 0x30 else {
                throw SideloadCertificateError.invalidFormat(errSecDecode)
            }
            try verifyPFXMac(macEl, in: p12Data, authSafeBytes: authSafeBytes, password: password)
            macVerified = true
        }

        guard let safeSeq = ASN1DER.readElement(in: authSafeBytes, at: authSafeBytes.startIndex),
              safeSeq.tag == 0x30,
              let contentInfos = ASN1DER.children(of: safeSeq, in: authSafeBytes),
              contentInfos.count <= maxBagsPerContainer else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        var state = ExtractionState(password: password, macVerified: macVerified)
        for ci in contentInfos {
            try parseContentInfo(ci, in: authSafeBytes, state: &state)
        }

        if !macVerified && !state.sawEncryptedPayload && !password.isEmpty {
            // A passwordless MAC-less `.p12` must reject non-empty passwords rather than silently accepting typos.
            throw SideloadCertificateError.wrongPassword
        }

        guard !state.privateKeysPKCS8.isEmpty, !state.certificatesDER.isEmpty else {
            throw SideloadCertificateError.missingIdentity
        }

        var matchedKey: SecKey?
        var matchedLeafDER: Data?
        for pkcs8 in state.privateKeysPKCS8 {
            guard let secKey = try? makeSecPrivateKey(fromPKCS8: pkcs8),
                  let pubData = publicKeyBytes(forPrivateKey: secKey) else {
                continue
            }
            if let leaf = state.certificatesDER.first(where: { publicKeyBytes(forCertificateDER: $0) == pubData }) {
                matchedKey = secKey
                matchedLeafDER = leaf
                break
            }
        }

        guard let privateKey = matchedKey, let leafDER = matchedLeafDER else {
            throw SideloadCertificateError.missingIdentity
        }
        guard let leafCert = SecCertificateCreateWithData(nil, leafDER as CFData),
              let leafInfo = X509CertificateParser.parse(der: leafDER) else {
            throw SideloadCertificateError.certificateUnreadable
        }

        var chainDER: [Data] = []
        for cert in state.certificatesDER where cert != leafDER && !chainDER.contains(cert) {
            chainDER.append(cert)
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
            identity: nil,
            privateKey: privateKey,
            leafCertificateDER: leafDER,
            chainCertificatesDER: chainDER,
            leafInfo: leafInfo,
            summary: summary,
            ephemeralKeychain: nil,
            ephemeralKeychainPath: nil
        )
        #else
        return SideloadSigningIdentity(
            identity: nil,
            privateKey: privateKey,
            leafCertificateDER: leafDER,
            chainCertificatesDER: chainDER,
            leafInfo: leafInfo,
            summary: summary
        )
        #endif
    }

    // MARK: - PFX MAC Verification

    private static func verifyPFXMac(_ macEl: ASN1DER.Element, in data: Data, authSafeBytes: Data, password: String) throws {
        guard let fields = ASN1DER.children(of: macEl, in: data), fields.count >= 2,
              fields[0].tag == 0x30,
              let digestInfo = ASN1DER.children(of: fields[0], in: data), digestInfo.count >= 2,
              digestInfo[0].tag == 0x30,
              let algFields = ASN1DER.children(of: digestInfo[0], in: data), let algOIDEl = algFields.first,
              algOIDEl.tag == 0x06,
              digestInfo[1].tag == 0x04,
              fields[1].tag == 0x04 else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        let expectedDigest = digestInfo[1].valueData(in: data)
        let salt = fields[1].valueData(in: data)
        var iterations = 1
        if fields.count >= 3, fields[2].tag == 0x02 {
            guard let parsedIter = readNonNegativeInt(fields[2], in: data),
                  parsedIter >= 1, parsedIter <= maxIterations else {
                throw SideloadCertificateError.invalidFormat(errSecDecode)
            }
            iterations = parsedIter
        }

        let hashKind = try resolveHashKind(oidBytes: algOIDEl.valueData(in: data))
        guard expectedDigest.count == hashKind.digestLength else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        for bmpPass in bmpPasswordCandidates(for: password) {
            let macKey = pkcs12DeriveBytes(
                hash: hashKind,
                idByte: 3,
                bmpPassword: bmpPass,
                salt: salt,
                iterations: iterations,
                outputLength: hashKind.digestLength
            )
            let computed = hashKind.hmac(key: macKey, message: authSafeBytes)
            if constantTimeEqual(computed, expectedDigest) {
                return
            }
        }
        throw SideloadCertificateError.wrongPassword
    }

    private static func resolveHashKind(oidBytes: Data) throws -> HashKind {
        switch oidBytes {
        case oidSHA1: return .sha1
        case oidSHA256: return .sha256
        case oidSHA384: return .sha384
        case oidSHA512: return .sha512
        default:
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
    }

    // MARK: - AuthenticatedSafe & SafeContents Traversal

    private struct ExtractionState {
        let password: String
        let macVerified: Bool
        var sawEncryptedPayload = false
        var privateKeysPKCS8: [Data] = []
        var certificatesDER: [Data] = []
    }

    private static func parseContentInfo(_ ci: ASN1DER.Element, in data: Data, state: inout ExtractionState) throws {
        guard ci.tag == 0x30,
              let fields = ASN1DER.children(of: ci, in: data), fields.count >= 2,
              fields[0].tag == 0x06,
              fields[1].tag == 0xA0,
              let explicitChildren = ASN1DER.children(of: fields[1], in: data),
              let inner = explicitChildren.first else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        let contentType = fields[0].valueData(in: data)
        if contentType == oidData {
            guard let safeBytes = extractOctetString(inner, in: data, depth: 0) else {
                throw SideloadCertificateError.invalidFormat(errSecDecode)
            }
            try parseSafeContents(safeBytes, depth: 0, state: &state)
        } else if contentType == oidEncryptedData {
            state.sawEncryptedPayload = true
            let safeBytes = try decryptEncryptedDataContent(inner, in: data, state: state)
            try parseSafeContents(safeBytes, depth: 0, state: &state)
        } else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
    }

    private static func decryptEncryptedDataContent(_ encDataEl: ASN1DER.Element, in data: Data, state: ExtractionState) throws -> Data {
        guard encDataEl.tag == 0x30,
              let encFields = ASN1DER.children(of: encDataEl, in: data), encFields.count >= 2,
              encFields[1].tag == 0x30,
              let eciFields = ASN1DER.children(of: encFields[1], in: data), eciFields.count >= 3,
              eciFields[0].tag == 0x06,
              eciFields[0].valueData(in: data) == oidData,
              eciFields[1].tag == 0x30 else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        guard let ciphertext = extractImplicitOctetString(eciFields[2], in: data, tagNumber: 0, depth: 0) else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        return try decryptExpectedASN1Sequence(
            algEl: eciFields[1],
            in: data,
            ciphertext: ciphertext,
            password: state.password,
            macVerified: state.macVerified
        )
    }

    private static func parseSafeContents(_ safeBytes: Data, depth: Int, state: inout ExtractionState) throws {
        guard depth <= maxNestingDepth,
              let seq = ASN1DER.readElement(in: safeBytes, at: safeBytes.startIndex),
              seq.tag == 0x30,
              let bags = ASN1DER.children(of: seq, in: safeBytes),
              bags.count <= maxBagsPerContainer else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        for bag in bags {
            guard bag.tag == 0x30,
                  let bagFields = ASN1DER.children(of: bag, in: safeBytes), bagFields.count >= 2,
                  bagFields[0].tag == 0x06,
                  bagFields[1].tag == 0xA0,
                  let explicit = ASN1DER.children(of: bagFields[1], in: safeBytes),
                  let bagValue = explicit.first else {
                throw SideloadCertificateError.invalidFormat(errSecDecode)
            }

            let bagOID = bagFields[0].valueData(in: safeBytes)
            switch bagOID {
            case oidKeyBag:
                guard bagValue.tag == 0x30 else {
                    throw SideloadCertificateError.invalidFormat(errSecDecode)
                }
                state.privateKeysPKCS8.append(bagValue.fullData(in: safeBytes))

            case oidPKCS8ShroudedKeyBag:
                state.sawEncryptedPayload = true
                let pkcs8 = try decryptEncryptedPrivateKeyInfo(bagValue, in: safeBytes, state: state)
                state.privateKeysPKCS8.append(pkcs8)

            case oidCertBag:
                if let certDER = try parseCertBag(bagValue, in: safeBytes) {
                    state.certificatesDER.append(certDER)
                }

            case oidSafeContentsBag:
                try parseSafeContents(bagValue.fullData(in: safeBytes), depth: depth + 1, state: &state)

            default:
                break
            }
        }
    }

    private static func decryptEncryptedPrivateKeyInfo(_ epkiEl: ASN1DER.Element, in data: Data, state: ExtractionState) throws -> Data {
        guard epkiEl.tag == 0x30,
              let fields = ASN1DER.children(of: epkiEl, in: data), fields.count >= 2,
              fields[0].tag == 0x30,
              let ciphertext = extractOctetString(fields[1], in: data, depth: 0) else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        return try decryptExpectedASN1Sequence(
            algEl: fields[0],
            in: data,
            ciphertext: ciphertext,
            password: state.password,
            macVerified: state.macVerified
        )
    }

    private static func parseCertBag(_ certBagEl: ASN1DER.Element, in data: Data) throws -> Data? {
        guard certBagEl.tag == 0x30,
              let fields = ASN1DER.children(of: certBagEl, in: data), fields.count >= 2,
              fields[0].tag == 0x06,
              fields[1].tag == 0xA0,
              let explicit = ASN1DER.children(of: fields[1], in: data),
              let certValueEl = explicit.first else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
        guard fields[0].valueData(in: data) == oidX509Certificate else {
            return nil
        }
        guard let certDER = extractOctetString(certValueEl, in: data, depth: 0) else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
        return certDER
    }

    // MARK: - Symmetric Decryption (PBES2 & PKCS#12 PBE)

    private static func decryptExpectedASN1Sequence(algEl: ASN1DER.Element, in data: Data, ciphertext: Data,
                                                    password: String, macVerified: Bool) throws -> Data {
        guard !ciphertext.isEmpty,
              let algFields = ASN1DER.children(of: algEl, in: data),
              let algOIDEl = algFields.first, algOIDEl.tag == 0x06 else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
        let algOID = algOIDEl.valueData(in: data)
        let paramsEl = algFields.count >= 2 ? algFields[1] : nil

        let plaintextOpt: Data?
        if algOID == oidPBES2 {
            guard let paramsEl else { throw SideloadCertificateError.invalidFormat(errSecDecode) }
            plaintextOpt = try decryptPBES2(paramsEl: paramsEl, in: data, ciphertext: ciphertext, password: password)
        } else if algOID == oidPBEWithSHAAnd3Key3DES
                    || algOID == oidPBEWithSHAAnd2Key3DES
                    || algOID == oidPBEWithSHAAnd128BitRC2
                    || algOID == oidPBEWithSHAAnd40BitRC2 {
            guard let paramsEl else { throw SideloadCertificateError.invalidFormat(errSecDecode) }
            plaintextOpt = try decryptPKCS12PBE(algOID: algOID, paramsEl: paramsEl, in: data, ciphertext: ciphertext, password: password)
        } else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        guard let plaintext = plaintextOpt,
              let top = ASN1DER.readElement(in: plaintext, at: plaintext.startIndex),
              top.tag == 0x30,
              top.fullRange.upperBound == plaintext.endIndex else {
            if !macVerified {
                throw SideloadCertificateError.wrongPassword
            }
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
        return plaintext
    }

    private static func decryptPBES2(paramsEl: ASN1DER.Element, in data: Data, ciphertext: Data, password: String) throws -> Data? {
        guard paramsEl.tag == 0x30,
              let fields = ASN1DER.children(of: paramsEl, in: data), fields.count >= 2,
              fields[0].tag == 0x30, fields[1].tag == 0x30,
              let kdfFields = ASN1DER.children(of: fields[0], in: data), kdfFields.count >= 2,
              kdfFields[0].tag == 0x06, kdfFields[0].valueData(in: data) == oidPBKDF2,
              kdfFields[1].tag == 0x30,
              let pbkdf2Params = ASN1DER.children(of: kdfFields[1], in: data), pbkdf2Params.count >= 2,
              pbkdf2Params[0].tag == 0x04, pbkdf2Params[1].tag == 0x02,
              let encSchemeFields = ASN1DER.children(of: fields[1], in: data), encSchemeFields.count >= 2,
              encSchemeFields[0].tag == 0x06, encSchemeFields[1].tag == 0x04 else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        let salt = pbkdf2Params[0].valueData(in: data)
        guard let iterations = readNonNegativeInt(pbkdf2Params[1], in: data),
              iterations >= 1, iterations <= maxIterations else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        var idx = 2
        var explicitKeyLen: Int?
        if idx < pbkdf2Params.count, pbkdf2Params[idx].tag == 0x02 {
            explicitKeyLen = readNonNegativeInt(pbkdf2Params[idx], in: data)
            idx += 1
        }
        var prfAlg = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        if idx < pbkdf2Params.count, pbkdf2Params[idx].tag == 0x30,
           let prfChildren = ASN1DER.children(of: pbkdf2Params[idx], in: data),
           let prfOIDEl = prfChildren.first, prfOIDEl.tag == 0x06 {
            switch prfOIDEl.valueData(in: data) {
            case oidHMACWithSHA1: prfAlg = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            case oidHMACWithSHA256: prfAlg = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case oidHMACWithSHA384: prfAlg = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            case oidHMACWithSHA512: prfAlg = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            default: throw SideloadCertificateError.invalidFormat(errSecDecode)
            }
        }

        let cipherOID = encSchemeFields[0].valueData(in: data)
        let iv = encSchemeFields[1].valueData(in: data)
        let ccAlg: CCAlgorithm
        let keyLen: Int
        let expectedIVLen: Int
        switch cipherOID {
        case oidAES128CBC:
            ccAlg = CCAlgorithm(kCCAlgorithmAES)
            keyLen = 16
            expectedIVLen = 16
        case oidAES192CBC:
            ccAlg = CCAlgorithm(kCCAlgorithmAES)
            keyLen = 24
            expectedIVLen = 16
        case oidAES256CBC:
            ccAlg = CCAlgorithm(kCCAlgorithmAES)
            keyLen = 32
            expectedIVLen = 16
        case oidDESEDE3CBC:
            ccAlg = CCAlgorithm(kCCAlgorithm3DES)
            keyLen = 24
            expectedIVLen = 8
        default:
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        if let explicitKeyLen, explicitKeyLen != keyLen {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
        guard iv.count == expectedIVLen else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        guard let key = derivePBKDF2Key(password: password, salt: salt, iterations: iterations, prf: prfAlg, keyLength: keyLen) else {
            return nil
        }
        return ccDecryptCBC(algorithm: ccAlg, key: key, iv: iv, ciphertext: ciphertext)
    }

    private static func decryptPKCS12PBE(algOID: Data, paramsEl: ASN1DER.Element, in data: Data,
                                         ciphertext: Data, password: String) throws -> Data? {
        guard paramsEl.tag == 0x30,
              let fields = ASN1DER.children(of: paramsEl, in: data), fields.count >= 2,
              fields[0].tag == 0x04, fields[1].tag == 0x02,
              let iterations = readNonNegativeInt(fields[1], in: data),
              iterations >= 1, iterations <= maxIterations else {
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }
        let salt = fields[0].valueData(in: data)

        let ccAlg: CCAlgorithm
        let derivedKeyBytes: Int
        let expand2Key3DES: Bool
        switch algOID {
        case oidPBEWithSHAAnd3Key3DES:
            ccAlg = CCAlgorithm(kCCAlgorithm3DES)
            derivedKeyBytes = 24
            expand2Key3DES = false
        case oidPBEWithSHAAnd2Key3DES:
            ccAlg = CCAlgorithm(kCCAlgorithm3DES)
            derivedKeyBytes = 16
            expand2Key3DES = true
        case oidPBEWithSHAAnd128BitRC2:
            ccAlg = CCAlgorithm(kCCAlgorithmRC2)
            derivedKeyBytes = 16
            expand2Key3DES = false
        case oidPBEWithSHAAnd40BitRC2:
            ccAlg = CCAlgorithm(kCCAlgorithmRC2)
            derivedKeyBytes = 5
            expand2Key3DES = false
        default:
            throw SideloadCertificateError.invalidFormat(errSecDecode)
        }

        for bmpPass in bmpPasswordCandidates(for: password) {
            var key = pkcs12DeriveBytes(hash: .sha1, idByte: 1, bmpPassword: bmpPass, salt: salt,
                                        iterations: iterations, outputLength: derivedKeyBytes)
            if expand2Key3DES {
                key.append(key.prefix(8))
            }
            let iv = pkcs12DeriveBytes(hash: .sha1, idByte: 2, bmpPassword: bmpPass, salt: salt,
                                       iterations: iterations, outputLength: 8)
            if let plain = ccDecryptCBC(algorithm: ccAlg, key: key, iv: iv, ciphertext: ciphertext),
               let top = ASN1DER.readElement(in: plain, at: plain.startIndex),
               top.tag == 0x30,
               top.fullRange.upperBound == plain.endIndex {
                return plain
            }
        }
        return nil
    }

    private static func derivePBKDF2Key(password: String, salt: Data, iterations: Int,
                                        prf: CCPseudoRandomAlgorithm, keyLength: Int) -> Data? {
        let passData = Data(password.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status: Int32 = salt.withUnsafeBytes { saltBuf in
            let saltPtr = saltBuf.bindMemory(to: UInt8.self).baseAddress
            if passData.isEmpty {
                // CommonCrypto rejects a NULL password pointer even when passwordLen == 0.
                var dummy: Int8 = 0
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    &dummy,
                    0,
                    saltPtr,
                    salt.count,
                    prf,
                    UInt32(iterations),
                    &derived,
                    keyLength
                )
            }
            return passData.withUnsafeBytes { passBuf in
                let passPtr = passBuf.bindMemory(to: Int8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr,
                    passData.count,
                    saltPtr,
                    salt.count,
                    prf,
                    UInt32(iterations),
                    &derived,
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    private static func ccDecryptCBC(algorithm: CCAlgorithm, key: Data, iv: Data, ciphertext: Data) -> Data? {
        let outCap = ciphertext.count + 32
        var outBytes = [UInt8](repeating: 0, count: outCap)
        var moved = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuf in
            iv.withUnsafeBytes { ivBuf in
                ciphertext.withUnsafeBytes { inBuf in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        algorithm,
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuf.baseAddress,
                        key.count,
                        ivBuf.baseAddress,
                        inBuf.baseAddress,
                        ciphertext.count,
                        &outBytes,
                        outCap,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved >= 0, moved <= outCap else { return nil }
        return Data(outBytes.prefix(moved))
    }

    // MARK: - RFC 7292 Appendix B.2 PKCS#12 KDF

    private static func bmpPasswordCandidates(for password: String) -> [Data] {
        if password.isEmpty {
            // Standard RFC 7292 encodes `""` as two zero terminator bytes (`0x00 0x00`), while OpenSSL's
            // empty-string path (`pass:""` vs NULL) may also use a 0-byte password buffer.
            return [Data([0x00, 0x00]), Data()]
        }
        var bmp = Data()
        bmp.reserveCapacity(password.utf16.count * 2 + 2)
        for unit in password.utf16 {
            bmp.append(UInt8((unit >> 8) & 0xff))
            bmp.append(UInt8(unit & 0xff))
        }
        bmp.append(contentsOf: [0x00, 0x00])
        return [bmp]
    }

    private static func pkcs12DeriveBytes(hash: HashKind, idByte: UInt8, bmpPassword: Data,
                                          salt: Data, iterations: Int, outputLength: Int) -> Data {
        let u = hash.digestLength
        let v = hash.blockLength
        let dBlock = [UInt8](repeating: idByte, count: v)

        let sLen = salt.isEmpty ? 0 : ((salt.count + v - 1) / v) * v
        let pLen = bmpPassword.isEmpty ? 0 : ((bmpPassword.count + v - 1) / v) * v
        var iBuf = [UInt8](repeating: 0, count: sLen + pLen)
        if sLen > 0 {
            let saltBytes = [UInt8](salt)
            for idx in 0..<sLen {
                iBuf[idx] = saltBytes[idx % saltBytes.count]
            }
        }
        if pLen > 0 {
            let passBytes = [UInt8](bmpPassword)
            for idx in 0..<pLen {
                iBuf[sLen + idx] = passBytes[idx % passBytes.count]
            }
        }

        let c = (outputLength + u - 1) / u
        var out = Data()
        out.reserveCapacity(c * u)

        for blockIdx in 1...max(1, c) {
            var hashInput = Data(dBlock)
            hashInput.append(contentsOf: iBuf)
            var a = hash.digest(hashInput)
            if iterations > 1 {
                for _ in 1..<iterations {
                    a = hash.digest(a)
                }
            }
            out.append(a)
            if blockIdx == c { break }

            let aBytes = [UInt8](a)
            var bPlusOne = [UInt8](repeating: 0, count: v)
            for idx in 0..<v {
                bPlusOne[idx] = aBytes[idx % aBytes.count]
            }
            // B = (B + 1) mod 2^(8v)
            var carry: UInt16 = 1
            for idx in stride(from: v - 1, through: 0, by: -1) {
                let sum = UInt16(bPlusOne[idx]) + carry
                bPlusOne[idx] = UInt8(sum & 0xff)
                carry = sum >> 8
                if carry == 0 { break }
            }

            // For each v-byte chunk I_j: I_j = (I_j + B + 1) mod 2^(8v)
            if !iBuf.isEmpty {
                for chunkStart in stride(from: 0, to: iBuf.count, by: v) {
                    var chunkCarry: UInt16 = 0
                    for idx in stride(from: v - 1, through: 0, by: -1) {
                        let sum = UInt16(iBuf[chunkStart + idx]) + UInt16(bPlusOne[idx]) + chunkCarry
                        iBuf[chunkStart + idx] = UInt8(sum & 0xff)
                        chunkCarry = sum >> 8
                    }
                }
            }
        }

        return Data(out.prefix(outputLength))
    }

    // MARK: - PKCS#8 PrivateKeyInfo -> SecKey & Public Key Matching

    private static func makeSecPrivateKey(fromPKCS8 pkcs8: Data) throws -> SecKey {
        guard let root = ASN1DER.readElement(in: pkcs8, at: pkcs8.startIndex),
              root.tag == 0x30,
              let fields = ASN1DER.children(of: root, in: pkcs8), fields.count >= 3,
              fields[0].tag == 0x02,
              fields[1].tag == 0x30,
              fields[2].tag == 0x04,
              let algChildren = ASN1DER.children(of: fields[1], in: pkcs8),
              let algOIDEl = algChildren.first, algOIDEl.tag == 0x06 else {
            throw SideloadCertificateError.missingIdentity
        }

        let algOID = algOIDEl.valueData(in: pkcs8)
        let privateKeyPayload = fields[2].valueData(in: pkcs8)

        if algOID == oidRSAEncryption {
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ]
            guard let secKey = SecKeyCreateWithData(privateKeyPayload as CFData, attrs as CFDictionary, nil) else {
                throw SideloadCertificateError.missingIdentity
            }
            return secKey
        }

        if algOID == oidECPublicKey {
            var curveOID = algChildren.count >= 2 && algChildren[1].tag == 0x06
                ? algChildren[1].valueData(in: pkcs8)
                : nil

            guard let ecSeq = ASN1DER.readElement(in: privateKeyPayload, at: privateKeyPayload.startIndex),
                  ecSeq.tag == 0x30,
                  let ecFields = ASN1DER.children(of: ecSeq, in: privateKeyPayload), ecFields.count >= 2,
                  ecFields[0].tag == 0x02,
                  ecFields[1].tag == 0x04 else {
                throw SideloadCertificateError.missingIdentity
            }

            let rawD = ecFields[1].valueData(in: privateKeyPayload)
            var explicitPubBitString: Data?
            for extra in ecFields.dropFirst(2) {
                if extra.tag == 0xA0, curveOID == nil,
                   let pChildren = ASN1DER.children(of: extra, in: privateKeyPayload),
                   let oidEl = pChildren.first, oidEl.tag == 0x06 {
                    curveOID = oidEl.valueData(in: privateKeyPayload)
                } else if extra.tag == 0xA1,
                          let pubChildren = ASN1DER.children(of: extra, in: privateKeyPayload),
                          let bitStr = pubChildren.first, bitStr.tag == 0x03 {
                    explicitPubBitString = bitStr.valueData(in: privateKeyPayload)
                }
            }

            let scalarLen: Int
            if curveOID == oidPrime256v1 || (curveOID == nil && rawD.count <= 32) {
                scalarLen = 32
            } else if curveOID == oidSecp384r1 || (curveOID == nil && rawD.count <= 48) {
                scalarLen = 48
            } else {
                throw SideloadCertificateError.missingIdentity
            }

            guard let dPadded = leftPadOrTrimLeadingZeros(rawD, to: scalarLen) else {
                throw SideloadCertificateError.missingIdentity
            }

            let x963Pub: Data
            if let bitStr = explicitPubBitString,
               bitStr.count == 1 + (1 + 2 * scalarLen),
               bitStr[bitStr.startIndex] == 0x00,
               bitStr[bitStr.startIndex + 1] == 0x04 {
                x963Pub = bitStr.dropFirst()
            } else if scalarLen == 32, let p256 = try? P256.Signing.PrivateKey(rawRepresentation: dPadded) {
                x963Pub = p256.publicKey.x963Representation
            } else if scalarLen == 48, let p384 = try? P384.Signing.PrivateKey(rawRepresentation: dPadded) {
                x963Pub = p384.publicKey.x963Representation
            } else {
                throw SideloadCertificateError.missingIdentity
            }

            var secKeyBytes = Data()
            secKeyBytes.reserveCapacity(x963Pub.count + dPadded.count)
            secKeyBytes.append(x963Pub)
            secKeyBytes.append(dPadded)

            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: scalarLen * 8,
            ]
            guard let secKey = SecKeyCreateWithData(secKeyBytes as CFData, attrs as CFDictionary, nil) else {
                throw SideloadCertificateError.missingIdentity
            }
            return secKey
        }

        throw SideloadCertificateError.missingIdentity
    }

    private static func publicKeyBytes(forPrivateKey privateKey: SecKey) -> Data? {
        guard let pubKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        return SecKeyCopyExternalRepresentation(pubKey, nil) as Data?
    }

    private static func publicKeyBytes(forCertificateDER der: Data) -> Data? {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let pubKey = SecCertificateCopyKey(cert) else { return nil }
        return SecKeyCopyExternalRepresentation(pubKey, nil) as Data?
    }

    // MARK: - Low-Level ASN.1 & Byte Helpers

    private static func readNonNegativeInt(_ el: ASN1DER.Element, in data: Data) -> Int? {
        let bytes = el.valueData(in: data)
        guard !bytes.isEmpty, bytes.count <= 8, (bytes[bytes.startIndex] & 0x80) == 0 else { return nil }
        var acc: UInt64 = 0
        for b in bytes {
            acc = (acc << 8) | UInt64(b)
        }
        guard acc <= UInt64(Int.max) else { return nil }
        return Int(acc)
    }

    private static func extractOctetString(_ el: ASN1DER.Element, in data: Data, depth: Int) -> Data? {
        guard depth <= maxNestingDepth else { return nil }
        if el.tag == 0x04 {
            return el.valueData(in: data)
        }
        if el.tag == 0x24, let parts = ASN1DER.children(of: el, in: data) {
            var combined = Data()
            for part in parts {
                guard let chunk = extractOctetString(part, in: data, depth: depth + 1) else { return nil }
                combined.append(chunk)
            }
            return combined
        }
        return nil
    }

    private static func extractImplicitOctetString(_ el: ASN1DER.Element, in data: Data, tagNumber: UInt8, depth: Int) -> Data? {
        let primitiveTag = 0x80 | (tagNumber & 0x1f)
        let constructedTag = 0xA0 | (tagNumber & 0x1f)
        if el.tag == primitiveTag {
            return el.valueData(in: data)
        }
        if el.tag == constructedTag, depth <= maxNestingDepth, let parts = ASN1DER.children(of: el, in: data) {
            var combined = Data()
            for part in parts {
                guard let chunk = extractOctetString(part, in: data, depth: depth + 1) else { return nil }
                combined.append(chunk)
            }
            return combined
        }
        return nil
    }

    private static func leftPadOrTrimLeadingZeros(_ raw: Data, to targetLength: Int) -> Data? {
        let trimmed = raw.drop { $0 == 0x00 }
        guard trimmed.count <= targetLength else { return nil }
        var out = Data(repeating: 0, count: targetLength - trimmed.count)
        out.append(trimmed)
        return out
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= (a ^ b)
        }
        return diff == 0
    }
}
