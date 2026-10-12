import Foundation
import CoreLocation
import os

/// Finds home locations from GPS density across the whole library — and,
/// since people move cities or countries over the years, finds as many
/// distinct homes as the data actually supports rather than assuming one.
///
/// Two signals combine, both needed:
///
/// 1. **Enough distinct days** (`homeMinDistinctDays`) — not photo count. A
///    single two-week vacation can out-produce months of home life in raw
///    photo volume, but home life shows up on far more *distinct days*.
/// 2. **Density within a continuous window** (`homeWindowDays`) — the
///    distinct days above must cluster inside one span of that length, not
///    be scattered thinly across the whole library. Without this, a place
///    visited for a handful of days every year or two over a decade (a
///    relative's house, a repeat vacation spot) can accumulate enough total
///    days to look like a home even though nobody ever lived there — it
///    never gets *dense* in any one stretch, which real residence does.
///
/// This is also how two real, sequential homes (lived in Providence through
/// 2018, then Sydney from 2018 on) both surface as separate candidates
/// instead of either blending together or one crowding out the other: each
/// is judged on its own residency window, not the full decades-long span.
struct HomeLocationDetector: Sendable {

    struct Candidate {
        var location: CLLocation
        var dayCount: Int
        /// The residency span actually observed — the qualifying window's
        /// first and last day, widened to include any contiguous-enough
        /// activity right around it. Shown in the UI so "this was home
        /// 2009–2018" reads naturally rather than as a raw density score.
        var firstDay: Date
        var lastDay: Date
    }

    private let log = Logger(subsystem: "app.photocurator", category: "home")

    func detect(in records: [PhotoRecord], settings: CuratorSettings) -> [Candidate] {
        let calendar = Calendar.current

        // Grid cell size in degrees, approximated from the home radius.
        // 1 degree of latitude is ~111km everywhere; longitude varies with
        // latitude, but this only seeds candidate centroids that get
        // refined by an actual CLLocation distance check below, so the
        // approximation only needs to be roughly right, not exact.
        let cellSizeDegrees = max(0.05, settings.homeRadius / 111_000)

        struct CellKey: Hashable { var latCell: Int; var lonCell: Int }
        var daysByCell: [CellKey: Set<Date>] = [:]
        var locationsByCell: [CellKey: [CLLocation]] = [:]

        for record in records {
            guard let location = record.location, let day = record.dayStart(calendar: calendar) else { continue }
            let key = CellKey(latCell: Int((location.coordinate.latitude / cellSizeDegrees).rounded(.down)),
                              lonCell: Int((location.coordinate.longitude / cellSizeDegrees).rounded(.down)))
            daysByCell[key, default: []].insert(day)
            locationsByCell[key, default: []].append(location)
        }

        // Candidate cells: enough distinct days to even consider, before the
        // more expensive windowed-density check. A cell below the raw total
        // can never pass the windowed check either, so this is a cheap
        // first filter, not a substitute for it.
        let roughCandidates = daysByCell
            .filter { $0.value.count >= settings.homeMinDistinctDays }
            .map(\.key)

        guard !roughCandidates.isEmpty else {
            log.notice("No home candidates: no location cluster reached \(settings.homeMinDistinctDays) distinct days at all")
            return []
        }

        // Merge adjacent qualifying cells (around the same real-world home)
        // into one location before the windowed check, so a home that
        // straddles a grid boundary is judged as a whole, not split into
        // two half-strength candidates that each fail the day-count bar.
        var merged: [(location: CLLocation, days: Set<Date>)] = []
        var consumed = Set<CellKey>()

        for key in roughCandidates.sorted(by: { (daysByCell[$0]?.count ?? 0) > (daysByCell[$1]?.count ?? 0) }) {
            guard !consumed.contains(key) else { continue }
            guard let centroid = PlaceSegmenter.centroid(of: locationsByCell[key] ?? []) else { continue }

            var groupLocations = locationsByCell[key] ?? []
            var groupDays = daysByCell[key] ?? []
            consumed.insert(key)

            for other in roughCandidates where !consumed.contains(other) {
                guard let otherCentroid = PlaceSegmenter.centroid(of: locationsByCell[other] ?? []) else { continue }
                if centroid.distance(from: otherCentroid) <= settings.homeRadius {
                    groupLocations.append(contentsOf: locationsByCell[other] ?? [])
                    groupDays.formUnion(daysByCell[other] ?? [])
                    consumed.insert(other)
                }
            }

            guard let finalCentroid = PlaceSegmenter.centroid(of: groupLocations) else { continue }
            merged.append((finalCentroid, groupDays))
        }

        // Windowed density check: does this location's activity actually
        // cluster densely in some continuous stretch, or is it thin and
        // spread across the whole library (a recurring visit, not a home)?
        var result: [Candidate] = []
        for group in merged {
            guard let window = Self.densestWindow(group.days, windowDays: settings.homeWindowDays,
                                                   minDistinctDays: settings.homeMinDistinctDays,
                                                   calendar: calendar) else { continue }
            result.append(Candidate(location: group.location, dayCount: group.days.count,
                                    firstDay: window.start, lastDay: window.end))
        }

        result.sort { $0.dayCount > $1.dayCount }
        log.notice("Detected \(result.count) home candidate(s) from \(merged.count) merged location cluster(s)")
        return result
    }

    /// True (and returns the observed span) when at least `minDistinctDays`
    /// of `days` fall within some window of `windowDays` length — a sliding
    /// check via a sorted-days two-pointer sweep, O(n). The returned span is
    /// widened to the full min/max of the days inside the best window found,
    /// so a home lived in for 9 years (far longer than the window itself)
    /// still reports its true start and end, not just one 18-month slice.
    static func densestWindow(_ days: Set<Date>, windowDays: Int, minDistinctDays: Int,
                              calendar: Calendar) -> (start: Date, end: Date)? {
        let sorted = days.sorted()
        guard sorted.count >= minDistinctDays else { return nil }

        let windowSeconds = TimeInterval(windowDays) * 86400
        var left = 0
        var bestCount = 0
        var bestRange: (Date, Date)?

        for right in sorted.indices {
            while sorted[right].timeIntervalSince(sorted[left]) > windowSeconds {
                left += 1
            }
            let count = right - left + 1
            if count > bestCount {
                bestCount = count
                bestRange = (sorted[left], sorted[right])
            }
        }

        guard bestCount >= minDistinctDays, let bestRange else { return nil }

        // Widen outward from the winning window only while density keeps
        // holding, so a long residency (far longer than one `windowDays`
        // slice) reports its true full start/end — but a gap of silence
        // (moved away, then came back years later) stops the widening
        // rather than bridging two separate stays into one false span.
        var startIndex = sorted.firstIndex(of: bestRange.0) ?? 0
        var endIndex = sorted.firstIndex(of: bestRange.1) ?? sorted.count - 1

        while startIndex > 0 {
            let gap = sorted[startIndex].timeIntervalSince(sorted[startIndex - 1])
            guard gap <= windowSeconds else { break }
            startIndex -= 1
        }
        while endIndex < sorted.count - 1 {
            let gap = sorted[endIndex + 1].timeIntervalSince(sorted[endIndex])
            guard gap <= windowSeconds else { break }
            endIndex += 1
        }

        return (sorted[startIndex], sorted[endIndex])
    }
}
