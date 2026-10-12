import Foundation
import CoreLocation

/// Splits one day's photos into place segments by GPS and time (PRD §10.2:
/// ~500m radius, 30 min gap). Each segment is a stop: a museum visit, a meal,
/// a neighbourhood walk.
///
/// This is distinct from `SimilarityClusterer`, which also uses time+GPS but
/// for near-duplicate detection within Tier 1/2. Here every photo in the day
/// is kept (no deletion involved); the output is purely a grouping for the
/// book layout and for naming trips.
struct PlaceSegmenter: Sendable {

    struct Segment: Identifiable {
        var id = UUID()
        var photoIds: [String]
        var startDate: Date
        var endDate: Date
        /// Centroid of the segment's located photos. Nil if none had GPS.
        var centroid: CLLocation?
    }

    /// `dayPhotos` need not be sorted; they are assumed to be one calendar
    /// day's worth (mixing days produces meaningless segments).
    func segment(_ dayPhotos: [PhotoRecord], settings: CuratorSettings) -> [Segment] {
        let sorted = dayPhotos.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        guard !sorted.isEmpty else { return [] }

        var segments: [[PhotoRecord]] = []
        var current: [PhotoRecord] = [sorted[0]]

        for record in sorted.dropFirst() {
            let last = current.last!
            if belongsToSameSegment(last, record, settings: settings) {
                current.append(record)
            } else {
                segments.append(current)
                current = [record]
            }
        }
        segments.append(current)

        return segments.map { members in
            let dates = members.compactMap(\.creationDate)
            let locations = members.compactMap(\.location)
            return Segment(photoIds: members.map(\.id),
                           startDate: dates.min() ?? Date(),
                           endDate: dates.max() ?? Date(),
                           centroid: Self.centroid(of: locations))
        }
    }

    private func belongsToSameSegment(_ a: PhotoRecord, _ b: PhotoRecord,
                                      settings: CuratorSettings) -> Bool {
        guard let dateA = a.creationDate, let dateB = b.creationDate else { return true }
        let gap = abs(dateB.timeIntervalSince(dateA))
        guard gap <= settings.placeSegmentMaxTimeGap else { return false }

        // GPS confirms a split only when both ends have it; missing GPS on
        // either side falls back to the time gap alone, since we cannot
        // measure a distance we do not have.
        if let locationA = a.location, let locationB = b.location {
            guard locationA.distance(from: locationB) <= settings.placeSegmentMaxDistance else {
                return false
            }
        }
        return true
    }

    /// Simple arithmetic-mean centroid. Good enough at the scale of one
    /// day's walking-distance segment; not meant for anything spanning a
    /// large area or crossing the antimeridian.
    static func centroid(of locations: [CLLocation]) -> CLLocation? {
        guard !locations.isEmpty else { return nil }
        let count = Double(locations.count)
        let lat = locations.reduce(0) { $0 + $1.coordinate.latitude } / count
        let lon = locations.reduce(0) { $0 + $1.coordinate.longitude } / count
        return CLLocation(latitude: lat, longitude: lon)
    }
}
