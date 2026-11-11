import Foundation
import ShellUI

/// Reads `ExpirationDate` from the app's `embedded.mobileprovision` so players using a 7-day free Apple ID signature
/// get a calm heads-up within 48 hours of expiry before iOS stops launching the app.
public enum ProvisioningProfile {
    /// Upper bound on profile file size (4 MiB) so a damaged or unexpected file never allocates unbounded memory.
    public static let maxProfileBytes = 4 * 1024 * 1024
    /// Warn when 48 hours or less remain on the provisioning profile.
    public static let warningWindow: TimeInterval = 48 * 3600

    /// Reads `ExpirationDate` from `Bundle.main`'s `embedded.mobileprovision`, or nil when absent or unreadable.
    public static func bundledExpiration(bundle: Bundle = .main, fileManager fm: FileManager = .default) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return expiration(at: url, fileManager: fm)
    }

    /// Reads `ExpirationDate` from a `.mobileprovision` file at `url`, returning nil safely on missing, oversize or damaged files.
    public static func expiration(at url: URL, fileManager fm: FileManager = .default) -> Date? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 0, size <= Int64(maxProfileBytes),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return expiration(fromProfile: data)
    }

    /// Extracts `ExpirationDate` from raw CMS-signed `.mobileprovision` bytes or a plain XML/binary property list.
    public static func expiration(fromProfile data: Data) -> Date? {
        guard !data.isEmpty, data.count <= maxProfileBytes else { return nil }
        if let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           let date = dict["ExpirationDate"] as? Date {
            return date
        }
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        guard let start = data.range(of: xmlStart),
              let end = data.range(of: xmlEnd, in: start.lowerBound..<data.endIndex),
              start.lowerBound < end.upperBound else {
            return nil
        }
        let slice = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = (try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        return dict["ExpirationDate"] as? Date
    }

    /// Returns the warning banner state when `expiration` is within 48 hours of `now` (including already expired), else nil.
    public static func warning(expiration: Date?, now: Date) -> SigningWarning? {
        guard let expiration else { return nil }
        let remaining = expiration.timeIntervalSince(now)
        guard remaining <= warningWindow else { return nil }
        if remaining <= 0 {
            return .expired
        }
        if remaining < 3600 {
            return .expiringSoon
        }
        let hours = max(1, Int((remaining / 3600).rounded(.down)))
        return .expiringHours(hours)
    }
}
