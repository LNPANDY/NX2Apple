import Foundation
import GameTime

package enum GameTimeMetrics {
    package static func cached(save: URL, cloudFolder: String?, titleID: String) -> UInt64? {
        let cloud = DMGameTimeCloudURL(cloudFolder, titleID)
        guard let local = DMGameTimeLocalURL(save, cloud, titleID) else { return nil }
        var error: NSError?
        return DMGameTimeTotal(local, &error)?.uint64Value
    }

    package static func refresh(save: URL, cloudFolder: String?, titleID: String) -> UInt64? {
        let cloud = DMGameTimeCloudURL(cloudFolder, titleID)
        guard let local = DMGameTimeLocalURL(save, cloud, titleID) else { return nil }
        var error: NSError?
        _ = DMGameTimeSynchronize(local, cloud, &error)
        if let error { NSLog("Play time: %@", error.localizedDescription) }
        return DMGameTimeTotal(local, &error)?.uint64Value
    }

    package static func duration(_ milliseconds: UInt64, locale: Locale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: Double(milliseconds) / 1000) ?? ""
    }
}
