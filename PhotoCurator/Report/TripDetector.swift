import Foundation
import CoreLocation

/// Detects candidate trips from day grouping, date gaps and home-location
/// exclusion together (PRD §10, full design, plus the requirement that
/// routine life at home is never offered as a trip).
///
/// A trip boundary forms only on a silent gap of at least `minGapDays`
/// between two active *away* days, or on an intervening home day (see
/// below) — **not** on GPS distance between consecutive away days. An
/// earlier version also split on a large same-day-to-day location jump
/// (`tripPlaceJumpDistance`), meant to catch a short side trip to another
/// city squeezed into ordinary life with no gap on either side. In
/// practice that rule fired on any multi-city itinerary with daily
/// photos — a Rome → Venice → Florence tour became three separate "trips"
/// purely because each city is >50km from the last, which is wrong for
/// the overwhelmingly more common case (one trip, several cities) and
/// matches neither Google Photos' nor Apple Photos' own trip grouping.
/// A real quick side-trip almost always still has at least one silent day
/// before or after it, which the gap rule alone catches correctly.
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
/// radius) and simply falls back to the date-gap signal alone.
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
    /// rather than a trip worth a book. Default raised from the original 8:
    /// an uncurated library (nothing moved to Tier 1/2 yet) can have plenty
    /// of small, scattered clusters of old, non-trip photos that technically
    /// clear a low bar — a real trip usually produces more than a handful.
    var minPhotosToQualify = 25

    /// Below this many distinct days, a run is a single bulk-imported or
    /// bulk-captured day (a photo scan session, an album restore, an event)
    /// rather than a multi-day trip — even if its photo count alone is high.
    /// A real trip is lived across more than one day.
    var minDayCount = 2

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

        // Home days are not trip material and must not count toward a
        // trip's photo total — but a home day sitting between two away
        // days must still end the first trip and start a new one, even
        // when the calendar gap it creates is shorter than `minGapDays`
        // (doc comment above: "they also act as a boundary themselves").
        // So `homeDays` is kept, sorted, alongside `awayDays`, purely to
        // answer "was there a home day strictly between these two away
        // days" in the loop below.
        let homeDays = Set(photosByDay.keys.filter { isHomeDay(photosByDay[$0] ?? [], homes: homes) })
        let awayDays = photosByDay.keys.filter { !homeDays.contains($0) }.sorted()
        guard !awayDays.isEmpty else { return [] }

        // Per-day centroid, kept for `hasAnyLocation` and place
        // segmentation below — no longer used for a boundary decision.
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

            // A home day strictly between these two away days ends the
            // trip on its own — being home at all means the days on
            // either side are not the same trip — regardless of whether
            // the calendar gap it creates also happens to clear
            // `minGapDays`.
            let hasHomeDayBetween = Self.anyDayBetween(previous, day, in: homeDays)

            if silentDays >= minGapDays || hasHomeDayBetween {
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
            // A single bulk-imported/captured day (a photo scan session, an
            // album restore) can have a high photo count without being a
            // trip at all — a real trip spans more than one day.
            guard days.count >= minDayCount else { return nil }

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

    /// Whether any day in `candidates` falls strictly between `start` and
    /// `end` (exclusive of both). Both inputs are already day-start dates
    /// (from `PhotoRecord.dayStart`), so plain `Date` comparison is exact —
    /// no calendar arithmetic needed.
    nonisolated static func anyDayBetween(_ start: Date, _ end: Date, in candidates: Set<Date>) -> Bool {
        guard start < end else { return false }
        return candidates.contains { $0 > start && $0 < end }
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
