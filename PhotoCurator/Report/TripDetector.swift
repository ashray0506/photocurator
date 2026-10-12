import Foundation
import CoreLocation

/// Detects candidate trips from day grouping, place segmentation, date gaps
/// and home-location exclusion together (PRD §10, full design, plus the
/// requirement that routine life at home is never offered as a trip).
///
/// A trip boundary forms when either:
/// 1. A silent gap of at least `minGapDays` separates two active *away*
///    days, or
/// 2. Consecutive active away days jump at least `tripPlaceJumpDistance`
///    apart, even with no date gap — this catches a same-week trip to
///    another city (fly out, spend three days, fly back) that a pure
///    date-gap detector would merge into ordinary life before and after it.
///
/// A day is **home** when the majority of its located photos fall within
/// any `HomeLocation`'s radius. Home days are dropped before any boundary or
/// qualification logic runs, and they also act as a boundary themselves —
/// three days at home between two trips separates them even if that gap is
/// shorter than `minGapDays`, since being home at all means the days on
/// either side are not the same trip.
///
/// GPS is used where available and never required: a day with no located
/// photos cannot be classified as home (there is nothing to check against a
/// radius) and simply falls back to the other two signals.
struct TripDetector {

    struct Candidate: Identifiable {
        var id: String { "\(startDay.timeIntervalSince1970)-\(endDay.timeIntervalSince1970)" }
        var startDay: Date
        var endDay: Date
        var photoIds: [String]
        var hasAnyLocation: Bool
        /// Place segments per day, keyed by day start. Populated by
        /// `detect(in:settings:homes:)`.
        var segmentsByDay: [Date: [PlaceSegmenter.Segment]] = [:]

        var dayCount: Int {
            Calendar.current.dateComponents([.day], from: startDay, to: endDay).day.map { $0 + 1 } ?? 1
        }
    }

    /// Minimum silent gap, in days, that alone separates two trips.
    var minGapDays = 3

    /// Below this many photos, a run of active away days is ordinary life
    /// rather than a trip worth a book.
    var minPhotosToQualify = 8

    /// `records` need not be sorted. Only survivors (not Tier 1/2) are
    /// meaningful for a book, but detection runs over whatever is passed.
    /// `homes` excludes everyday life at a detected or user-added home
    /// location from ever being offered as a trip.
    func detect(in records: [PhotoRecord], settings: CuratorSettings = .default,
               homes: [HomeLocation] = []) -> [Candidate] {
        let calendar = Calendar.current
        var photosByDay: [Date: [PhotoRecord]] = [:]

        for record in records {
            guard let day = record.dayStart(calendar: calendar) else { continue }
            photosByDay[day, default: []].append(record)
        }

        // Drop home days before anything else: they are not trip material
        // and must not count toward a trip's photo total or act as a
        // same-location anchor for the place-jump check.
        let awayDays = photosByDay.keys
            .filter { !isHomeDay(photosByDay[$0] ?? [], homes: homes) }
            .sorted()
        guard !awayDays.isEmpty else { return [] }

        // Per-day centroid, for the place-jump boundary signal.
        var centroidByDay: [Date: CLLocation] = [:]
        for day in awayDays {
            let locations = (photosByDay[day] ?? []).compactMap(\.location)
            if let centroid = PlaceSegmenter.centroid(of: locations) {
                centroidByDay[day] = centroid
            }
        }

        var runs: [[Date]] = []
        var current: [Date] = [awayDays[0]]

        for day in awayDays.dropFirst() {
            let previous = current.last!
            let dayGap = calendar.dateComponents([.day], from: previous, to: day).day ?? 0
            let silentDays = dayGap - 1   // counts both a plain gap and any home days in between

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

    /// A day is home when most of its *located* photos sit inside some
    /// home's radius. Unlocated photos on that day neither count for nor
    /// against the determination (there is nothing to check), and a day
    /// with zero located photos is never classified as home — it stays
    /// available to the date-gap signal like any other GPS-less day.
    private func isHomeDay(_ dayPhotos: [PhotoRecord], homes: [HomeLocation]) -> Bool {
        guard !homes.isEmpty else { return false }
        let locations = dayPhotos.compactMap(\.location)
        guard !locations.isEmpty else { return false }

        let homeCount = locations.filter { location in
            homes.contains { $0.contains(location) }
        }.count

        return Double(homeCount) / Double(locations.count) > 0.5
    }
}
