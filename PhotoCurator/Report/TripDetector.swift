import Foundation

/// Detects candidate trips from date gaps alone (PRD §10, adapted).
///
/// The PRD's original design clusters by day then by GPS segment within a
/// day (§10.2: ~500m radius, 30 min gap) and names places by reverse
/// geocoding. That assumes most photos carry location — this library
/// doesn't (see the scan report: the overwhelming majority of days show "no
/// GPS"), so segmenting by place would silently produce almost nothing.
///
/// Trip *boundaries* come from date gaps instead: a run of days with photos,
/// separated from the next run by at least `minGapDays` of silence, is one
/// candidate trip. This works for any library regardless of GPS coverage.
/// GPS is used opportunistically within a trip (for an optional route map)
/// but never required to form one.
struct TripDetector {

    struct Candidate: Identifiable {
        var id: String { "\(startDay.timeIntervalSince1970)-\(endDay.timeIntervalSince1970)" }
        var startDay: Date
        var endDay: Date
        var photoIds: [String]
        var hasAnyLocation: Bool

        var dayCount: Int {
            Calendar.current.dateComponents([.day], from: startDay, to: endDay).day.map { $0 + 1 } ?? 1
        }
    }

    /// Minimum silent gap, in days, that separates two trips. Below this,
    /// two active runs merge into one trip (e.g. a single rest day inside a
    /// longer trip should not split it in two).
    var minGapDays = 3

    /// Below this many photos, a run of active days is treated as ordinary
    /// day-to-day life rather than a trip worth building a book from.
    var minPhotosToQualify = 8

    /// `records` need not be sorted. Only survivors (not Tier 1/2) are
    /// meaningful for a book, but detection runs over whatever is passed so
    /// callers can decide.
    func detect(in records: [PhotoRecord]) -> [Candidate] {
        let calendar = Calendar.current
        var photosByDay: [Date: [String]] = [:]
        var locatedDays = Set<Date>()

        for record in records {
            guard let day = record.dayStart(calendar: calendar) else { continue }
            photosByDay[day, default: []].append(record.id)
            if record.location != nil { locatedDays.insert(day) }
        }

        let activeDays = photosByDay.keys.sorted()
        guard !activeDays.isEmpty else { return [] }

        var runs: [[Date]] = []
        var current: [Date] = [activeDays[0]]

        for day in activeDays.dropFirst() {
            let previous = current.last!
            let gap = calendar.dateComponents([.day], from: previous, to: day).day ?? 0
            if gap - 1 >= minGapDays {
                runs.append(current)
                current = [day]
            } else {
                current.append(day)
            }
        }
        runs.append(current)

        return runs.compactMap { days -> Candidate? in
            let photoIds = days.flatMap { photosByDay[$0] ?? [] }
            guard photoIds.count >= minPhotosToQualify else { return nil }
            return Candidate(startDay: days.first!,
                             endDay: days.last!,
                             photoIds: photoIds,
                             hasAnyLocation: days.contains { locatedDays.contains($0) })
        }
    }
}
