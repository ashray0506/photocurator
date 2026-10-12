import Foundation

/// A sticker placed on a book page (decoration only — per product
/// requirement, this never touches the source photo; it's drawn on top at
/// export time, the same way a caption is).
struct PageSticker: Codable, Sendable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var emoji: String
    /// Normalised 0...1 position on the page, so it survives any page-size
    /// change between the editor and the exported PDF.
    var x: Double
    var y: Double
    var scale: Double = 1.0

    /// A sensible emoji palette covering what both kids and adults reach
    /// for on a travel photo — not exhaustive, just a curated starting set
    /// rather than the full system emoji picker, which would be overkill
    /// for "decorate a page."
    static let palette = [
        "⭐️", "❤️", "🎉", "✈️", "📍", "🌅", "🏖️", "🗺️",
        "🍜", "📸", "🐶", "🐱", "🌸", "🔥", "😂", "😍"
    ]
}

/// A page's caption styling — a few named presets rather than a full font
/// picker, so a page stays readable and on-brand. Per-day, not per-trip,
/// since different pages may suit different moods (a kid's silly day vs.
/// a quiet grown-up one).
enum PageCaptionStyle: String, Codable, Sendable, CaseIterable {
    case classic      // the default: serif, neutral
    case playful      // rounded, warm color — the "kids" preset
    case minimal      // small caps, muted

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .playful: return "Playful"
        case .minimal: return "Minimal"
        }
    }
}

/// One place segment within a trip day, with its resolved name (PRD §10.2,
/// §10.3). Stored (not recomputed each time) because reverse geocoding is a
/// network call and should not re-run every time a trip is opened.
struct TripPlaceSegment: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var placeName: String?   // nil if geocoding failed or found nothing
    var startDate: Date
    var endDate: Date
    var photoIds: [String]
}

/// A user-confirmed trip: a named date range built from a `TripDetector`
/// candidate, persisted so naming, place segments and boundary edits survive
/// a relaunch.
///
/// This is a simplified stand-in for the PRD §11 `Book` model. The PRD's
/// version adds per-day AI titles/captions and a MapKit route snapshot —
/// still deferred (captions need a decision about sending text to the
/// Anthropic API, PRD §14; route maps are straightforward to add once place
/// data proved itself, which this update does).
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
    /// Place segments per day, keyed by the day's start-of-day timestamp
    /// (as a string, since Dictionary isn't directly Codable with Date keys
    /// across all encoders) — populated once, lazily, the first time a trip
    /// is opened and geocoding completes.
    var placeSegmentsByDay: [String: [TripPlaceSegment]] = [:]
    /// The book's chosen photos per day (PRD §10.4: best 3 to 6 per day),
    /// same key shape as `placeSegmentsByDay`. Populated lazily the first
    /// time a trip's book is opened (`LibraryScanner.selectedPhotos(for:)`);
    /// empty until then, which callers read as "not yet chosen, show every
    /// survivor for this day" rather than "deliberately empty day".
    var selectedPhotoIdsByDay: [String: [String]] = [:]
    /// Decorative stickers per day — purely cosmetic, drawn at export time;
    /// the underlying photos are never modified.
    var stickersByDay: [String: [PageSticker]] = [:]
    /// Caption style per day, defaulting to `.classic` when unset.
    var captionStyleByDay: [String: PageCaptionStyle] = [:]
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, startDay: Date, endDay: Date,
        photoIds: [String], placeSegmentsByDay: [String: [TripPlaceSegment]] = [:],
        selectedPhotoIdsByDay: [String: [String]] = [:],
        stickersByDay: [String: [PageSticker]] = [:],
        captionStyleByDay: [String: PageCaptionStyle] = [:],
        createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.startDay = startDay
        self.endDay = endDay
        self.photoIds = photoIds
        self.placeSegmentsByDay = placeSegmentsByDay
        self.selectedPhotoIdsByDay = selectedPhotoIdsByDay
        self.stickersByDay = stickersByDay
        self.captionStyleByDay = captionStyleByDay
        self.createdAt = createdAt
    }

    static func dayKey(_ day: Date) -> String {
        String(day.timeIntervalSinceReferenceDate)
    }

    func segments(for day: Date) -> [TripPlaceSegment] {
        placeSegmentsByDay[Self.dayKey(day)] ?? []
    }

    func stickers(for day: Date) -> [PageSticker] {
        stickersByDay[Self.dayKey(day)] ?? []
    }

    func captionStyle(for day: Date) -> PageCaptionStyle {
        captionStyleByDay[Self.dayKey(day)] ?? .classic
    }

    /// All distinct place names across the trip, in first-seen order —
    /// used to build a place-based suggested name (PRD §10.3: e.g. "Seoul,
    /// South Korea") once segments are resolved.
    var distinctPlaceNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for day in placeSegmentsByDay.keys.sorted() {
            for segment in placeSegmentsByDay[day] ?? [] {
                guard let name = segment.placeName, !seen.contains(name) else { continue }
                seen.insert(name)
                ordered.append(name)
            }
        }
        return ordered
    }

    static func suggestedName(startDay: Date, endDay: Date, placeNames: [String] = []) -> String {
        if let first = placeNames.first {
            // "Seoul, South Korea" or "Seoul, South Korea + 2 more" for a
            // multi-city trip, so the name stays short.
            if placeNames.count > 1 {
                return "\(first) + \(placeNames.count - 1) more"
            }
            return first
        }

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
