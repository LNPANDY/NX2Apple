// Verifies an nxkit release's SHA256SUMS.sig the way the launcher does (NxkitUpdate.verifySignature): Ed25519 over the exact bytes of the file,
// the signature one line of base64 of its 64 bytes, the key base64 of its 32 raw bytes. Used by nxbuild.py, which has no Ed25519 of its own.
//   swift verify_ed25519.swift <public key base64> <file> <signature file>
// Exit 0: the signature verifies. Exit 1: it does not. Exit 2: wrong arguments or unreadable input.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let rawKey = Data(base64Encoded: args[1].trimmingCharacters(in: .whitespacesAndNewlines)), rawKey.count == 32,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
      let file = FileManager.default.contents(atPath: args[2]),
      let sigData = FileManager.default.contents(atPath: args[3]),
      let sigText = String(data: sigData, encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: verify_ed25519.swift <public key base64> <file> <signature file>\n".utf8))
    exit(2)
}
guard let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64 else { exit(1) }
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
