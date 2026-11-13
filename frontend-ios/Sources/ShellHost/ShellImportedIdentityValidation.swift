import Foundation
import ZsignC

/// Matches an import to the installed executable, not merely another certificate
/// issued to the same team. This is not Apple trust or device authorization.
enum ShellImportedIdentityValidation {
    static func validate(pkcs12: Data, profile: Data, password: String, executable: URL?) throws {
        typealias Failure = ShellSigningIdentityStore.Failure
        guard let executable,
              let signature = FrameworkSignature.inspect(executable: executable),
              signature.hasCodeSignature, let hostTeam = signature.teamID, !hostTeam.isEmpty,
              let cms = signatureCMS(executable: executable, signature: signature) else {
            throw Failure.hostSignatureUnavailable
        }
        guard let provision = profileDictionary(profile),
              let expiration = provision["ExpirationDate"] as? Date, expiration > Date() else {
            throw Failure.expired
        }
        guard let teams = provision["TeamIdentifier"] as? [String], teams.first == hostTeam else {
            throw Failure.invalid
        }
        var certificate = [UInt8](repeating: 0, count: 64 * 1024)
        let capacity = certificate.count
        var certificateSize = 0
        let result = pkcs12.withUnsafeBytes { p12 in
            cms.withUnsafeBytes { signature in
                zsign_validate_imported_identity(
                    p12.bindMemory(to: UInt8.self).baseAddress, p12.count, password,
                    signature.bindMemory(to: UInt8.self).baseAddress, signature.count,
                    &certificate, capacity, &certificateSize)
            }
        }
        switch result {
        case 0: break
        case 2: throw Failure.hostSignatureUnavailable
        case 3: throw Failure.signerMismatch
        default: throw Failure.invalid
        }
        guard let certificates = provision["DeveloperCertificates"] as? [Data],
              certificates.contains(Data(certificate.prefix(certificateSize))) else {
            throw Failure.certificateNotInProfile
        }
    }

    static func certificateExpiration(executable: URL) -> Date? {
        guard let signature = FrameworkSignature.inspect(executable: executable),
              let cms = signatureCMS(executable: executable, signature: signature) else { return nil }
        var seconds: Int64 = 0
        let result = cms.withUnsafeBytes { bytes in
            zsign_copy_signer_expiration(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &seconds)
        }
        return result == 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }

    static func signatureCMS(executable: URL, signature: FrameworkSignature.Info) -> Data? {
        guard signature.hasCodeSignature, signature.signatureSize >= 12,
              Int(signature.signatureSize) <= FrameworkSignature.maxSignatureBytes,
              signature.sliceOffset <= UInt64.max - UInt64(signature.signatureOffset),
              let input = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? input.close() }
        do {
            try input.seek(toOffset: signature.sliceOffset + UInt64(signature.signatureOffset))
            guard let blob = try input.read(upToCount: Int(signature.signatureSize)),
                  blob.count == Int(signature.signatureSize) else { return nil }
            return cms(inSuperBlob: blob)
        } catch { return nil }
    }

    static func cms(inSuperBlob blob: Data) -> Data? {
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(blob[blob.startIndex + offset + $1]) }
        }
        guard blob.count >= 12, word(0) == 0xfade0cc0 else { return nil }
        let length = word(4), count = word(8)
        guard length >= 12, length <= blob.count, count <= (length - 12) / 8 else { return nil }
        var cms: Data?
        for index in 0..<count {
            let slot = 12 + index * 8
            guard word(slot) == 0x10000 else { continue } // CSSLOT_SIGNATURESLOT
            let offset = word(slot + 4)
            guard cms == nil, offset >= 12 + count * 8, offset <= length - 8,
                  word(offset) == 0xfade0b01 else { return nil } // CSMAGIC_BLOBWRAPPER
            let size = word(offset + 4)
            guard size > 8, size <= length - offset else { return nil }
            cms = blob.subdata(in: offset + 8..<offset + size)
        }
        return cms
    }

    static func profileDictionary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= ProvisioningProfile.maxProfileBytes else { return nil }
        let capacity = data.count
        var content = [UInt8](repeating: 0, count: capacity)
        var contentSize = 0
        let result = data.withUnsafeBytes { profile in
            zsign_copy_profile_content(profile.bindMemory(to: UInt8.self).baseAddress,
                                          profile.count, &content, capacity, &contentSize)
        }
        guard result == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: Data(content.prefix(contentSize)), format: nil) as? [String: Any]
    }
}
