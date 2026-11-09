import Foundation

package enum OfflineSigning {
    enum IdentityError: Error { case unavailable }
    /// Read the identity of the app produced by the engine rather than silently
    /// replacing an explicit --mac-sign selection with an ad-hoc signature.
    package static func identity(from details: String) throws -> String {
        let lines = details.split(separator: "\n").map(String.init)
        if let authority = lines.first(where: { $0.hasPrefix("Authority=") }) {
            let identity = String(authority.dropFirst("Authority=".count))
            guard !identity.isEmpty else { throw IdentityError.unavailable }
            return identity
        }
        if lines.contains(where: { $0 == "Signature=adhoc" }) { return "-" }
        throw IdentityError.unavailable
    }
}
