import Foundation

package enum DeviceGPU {
    static let targetsByChip = ["8150": "g18p", "8160": "g19p"]

    package static func target(udid: String) -> String? {
        let parts = udid.split(separator: "-")
        guard parts.count == 2, parts[0].count == 8, parts[0].hasPrefix("0000") else { return nil }
        return targetsByChip[String(parts[0].dropFirst(4))]
    }
}
