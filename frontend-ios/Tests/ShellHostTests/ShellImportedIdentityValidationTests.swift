import Foundation
import XCTest
@testable import ShellHost

final class ShellImportedIdentityValidationTests: XCTestCase {
    private func blob(slots: [(UInt32, Data)]) -> Data {
        func word(_ value: UInt32) -> Data {
            Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                  UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        var index = Data(), payload = Data()
        for (slot, content) in slots {
            index.append(word(slot))
            index.append(word(UInt32(12 + slots.count * 8 + payload.count)))
            payload.append(word(0xfade0b01))
            payload.append(word(UInt32(content.count + 8)))
            payload.append(content)
        }
        return word(0xfade0cc0) + word(UInt32(12 + index.count + payload.count))
            + word(UInt32(slots.count)) + index + payload
    }

    func testFindsOnlyCMSInSignatureSlot() {
        let cms = Data([0x30, 1, 2, 3])
        XCTAssertEqual(ShellImportedIdentityValidation.cms(inSuperBlob:
            blob(slots: [(0, Data([9])), (0x10000, cms)])), cms)
        XCTAssertNil(ShellImportedIdentityValidation.cms(inSuperBlob: blob(slots: [(0, cms)])))
    }

    func testRejectsMissingDuplicateEmptyAndTruncatedCMS() {
        let valid = blob(slots: [(0x10000, Data([1, 2, 3]))])
        XCTAssertNil(ShellImportedIdentityValidation.cms(inSuperBlob: Data()))
        XCTAssertNil(ShellImportedIdentityValidation.cms(inSuperBlob: blob(slots: [])))
        XCTAssertNil(ShellImportedIdentityValidation.cms(inSuperBlob: blob(slots: [(0x10000, Data())])))
        XCTAssertNil(ShellImportedIdentityValidation.cms(inSuperBlob:
            blob(slots: [(0x10000, Data([1])), (0x10000, Data([2]))])))
        for count in 0..<valid.count {
            XCTAssertNil(ShellImportedIdentityValidation.cms(inSuperBlob: Data(valid.prefix(count))))
        }
    }

    func testPlainPlistsCannotBeImportedAsProvisioningProfiles() throws {
        let profile: [String: Any] = ["TeamIdentifier": ["TESTTEAM01"], "DeveloperCertificates": [Data([1])]]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: format, options: 0)
            XCTAssertNil(ShellImportedIdentityValidation.profileDictionary(data))
        }
    }

    func testAbsentHostCannotValidateImport() {
        XCTAssertThrowsError(try ShellImportedIdentityValidation.validate(
            pkcs12: Data([1]), profile: Data([1]), password: "", executable: nil)) {
            guard case ShellSigningIdentityStore.Failure.hostSignatureUnavailable = $0 else {
                return XCTFail("Expected missing installed signer")
            }
        }
    }
}
