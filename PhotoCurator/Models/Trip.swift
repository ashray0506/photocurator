import Foundation

/// A user-confirmed trip: a named date range built from a `TripDetector`
/// candidate, persisted so naming and boundary edits survive a relaunch.
///
/// This is a simplified stand-in for the PRD §11 `Book` model. The PRD's
/// version adds per-day titles, captions and route points — deferred along
/// with AI captions and route maps (this library has too little GPS data to
/// make route maps worthwhile, and captions need a decision about sending
/// text to the Anthropic API, PRD §14).
struct Trip: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var startDay: Date
    var endDay: Date
    /// All survivor photo ids in range at the time this trip was created or
    /// last refreshed. Re-detection (a rescan) does not overwrite this —
    /// trips are edited explicitly, not silently recomputed out from under
    /// the user.
    var photoIds: [String]
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, startDay: Date, endDay: Date,
        photoIds: [String], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.startDay = startDay
        self.endDay = endDay
        self.photoIds = photoIds
        self.createdAt = createdAt
    }

    static func suggestedName(startDay: Date, endDay: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: startDay)
        if Calendar.current.isDate(startDay, inSameDayAs: endDay) {
            return "Trip — \(start)"
        }
        let end = formatter.string(from: endDay)
        return "Trip — \(start) to \(end)"
    }
}
