import Foundation
import CoreLocation

/// A place treated as "everyday life" rather than a trip destination.
/// Auto-detected from GPS density, user-editable, user-addable (per the
/// product requirement: not every GPS-dense date range is a trip — time
/// spent at home or in a home city should never be offered as one).
struct HomeLocation: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// Metres. Defaults to `CuratorSettings.homeRadius` at creation but is
    /// stored per-home so a user can widen or narrow one individually
    /// (e.g. a small town home vs. a large home city).
    var radius: Double
    var isAutoDetected: Bool
    /// Only meaningful for auto-detected homes: how many distinct days of
    /// photos were seen within this cluster, which is what qualified it.
    var distinctDayCount: Int
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, latitude: Double, longitude: Double,
        radius: Double, isAutoDetected: Bool, distinctDayCount: Int = 0,
        createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.isAutoDetected = isAutoDetected
        self.distinctDayCount = distinctDayCount
        self.createdAt = createdAt
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func contains(_ other: CLLocation) -> Bool {
        location.distance(from: other) <= radius
    }
}
