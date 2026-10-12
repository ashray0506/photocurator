import Foundation
import CoreLocation

/// Detects candidate trips from day grouping, place segmentation and date
/// gaps together (PRD §10, full design).
///
/// A trip boundary forms when either:
/// 1. A silent gap of at least `minGapDays` separates two active days, or
/// 2. Consecutive active days jump at least `tripPlaceJumpDistance` apart,
///    even with no date gap — this catches a same-week trip to another city
///    (fly out, spend three days, fly back) that a pure date-gap detector
///    would merge into ordinary life before and after it.
///
/// GPS is used where available and never required: a day with no located
/// photos simply cannot contribute to signal 2, and falls back to signal 1.
struct TripDetector {

    struct Candidate: Identifiable {
        var id: String { "\(startDay.timeIntervalSince1970)-\(endDay.timeIntervalSince1970)" }
        var startDay: Date
        var endDay: Date
        var photoIds: [String]
        var hasAnyLocation: Bool
        /// Place segments per day, keyed by day start. Populated by
        /// `detect(in:settings:)`; empty from the geocoding-free variant.
        var segmentsByDay: [Date: [PlaceSegmenter.Segment]] = [:]

        var dayCount: Int {
            Calendar.current.dateComponents([.day], from: startDay, to: endDay).day.map { $0 + 1 } ?? 1
        }
    }

    /// Minimum silent gap, in days, that alone separates two trips.
    var minGapDays = 3

    /// Below this many photos, a run of active days is ordinary life rather
    /// than a trip worth a book.
    var minPhotosToQualify = 8

    /// `records` need not be sorted. Only survivors (not Tier 1/2) are
    /// meaningful for a book, but detection runs over whatever is passed.
    func detect(in records: [PhotoRecord], settings: CuratorSettings = .default) -> [Candidate] {
        let calendar = Calendar.current
        var photosByDay: [Date: [PhotoRecord]] = [:]

        for record in records {
            guard let day = record.dayStart(calendar: calendar) else { continue }
            photosByDay[day, default: []].append(record)
        }

        let activeDays = photosByDay.keys.sorted()
        guard !activeDays.isEmpty else { return [] }

        // Per-day centroid, for the place-jump boundary signal.
        var centroidByDay: [Date: CLLocation] = [:]
        for (day, dayPhotos) in photosByDay {
            let locations = dayPhotos.compactMap(\.location)
            if let centroid = PlaceSegmenter.centroid(of: locations) {
                centroidByDay[day] = centroid
            }
        }

        var runs: [[Date]] = []
        var current: [Date] = [activeDays[0]]

        for day in activeDays.dropFirst() {
            let previous = current.last!
            let dayGap = calendar.dateComponents([.day], from: previous, to: day).day ?? 0
            let silentDays = dayGap - 1

            let placeJumped: Bool
            if let centroidA = centroidByDay[previous], let centroidB = centroidByDay[day] {
                placeJumped = centroidA.distance(from: centroidB) >= settings.tripPlaceJumpDistance
            } else {
                placeJumped = false   // no GPS on one side: cannot measure a jump, so don't claim one
            }

            if silentDays >= minGapDays || placeJumped {
                runs.append(current)
                current = [day]
            } else {
                current.append(day)
            }
        }
        runs.append(current)

        let segmenter = PlaceSegmenter()

        return runs.compactMap { days -> Candidate? in
            let dayPhotos = days.flatMap { photosByDay[$0] ?? [] }
            let photoIds = dayPhotos.map(\.id)
            guard photoIds.count >= minPhotosToQualify else { return nil }

            var segmentsByDay: [Date: [PlaceSegmenter.Segment]] = [:]
            for day in days {
                segmentsByDay[day] = segmenter.segment(photosByDay[day] ?? [], settings: settings)
            }

            return Candidate(startDay: days.first!,
                             endDay: days.last!,
                             photoIds: photoIds,
                             hasAnyLocation: days.contains { centroidByDay[$0] != nil },
                             segmentsByDay: segmentsByDay)
        }
    }
}
