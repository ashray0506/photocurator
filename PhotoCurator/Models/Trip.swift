import Foundation
import CoreLocation

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
    /// The fuller, neighbourhood-aware label ("I Municipio, Rome") — used
    /// for a day page's place caption, where that extra detail is useful.
    var placeName: String?   // nil if geocoding failed or found nothing
    /// City-level only, never a neighbourhood — the naming minimum
    /// requested directly ("minimum should be city except home"). Trip
    /// names build from this, not `placeName`, so a trip never degrades
    /// below city level the way "I Municipio, Rome + 5 more" did.
    /// Nil alongside `country` for segments geocoded before these fields
    /// existed, or wherever the placemark had no locality/admin area at
    /// all — decodes to nil for old persisted trips rather than failing,
    /// since `Codable`'s synthesized init treats a missing key as using
    /// this default.
    var city: String? = nil
    var country: String? = nil
    /// The segment's centroid coordinate, persisted so the journey map can
    /// plot a real route without re-deriving GPS from each photo live.
    /// Nil for segments saved before the map feature existed, or with no
    /// located photos at all — the map simply skips those stops.
    var latitude: Double? = nil
    var longitude: Double? = nil
    var startDate: Date
    var endDate: Date
    var photoIds: [String]

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
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

    /// One stop per day, in date order, for the journey map's animated
    /// route — the day's first located segment's centroid (a day can have
    /// several stops; the map draws day-to-day, not stop-to-stop, to keep
    /// the route legible). Days with no located photos at all are simply
    /// absent, so the route may have fewer points than `dayCount` on a
    /// trip with sparse GPS.
    struct RouteStop: Identifiable {
        var id: String   // the day key
        var day: Date
        var coordinate: CLLocationCoordinate2D
        var placeName: String?
        var country: String?
    }

    var dailyRoute: [RouteStop] {
        var stops: [RouteStop] = []
        for (dayKey, segments) in placeSegmentsByDay {
            guard let first = segments.sorted(by: { $0.startDate < $1.startDate }).first(where: { $0.coordinate != nil }),
                  let coordinate = first.coordinate else { continue }
            stops.append(RouteStop(id: dayKey, day: first.startDate, coordinate: coordinate,
                                   placeName: first.city ?? first.placeName, country: first.country))
        }
        return stops.sorted { $0.day < $1.day }
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

    /// One geocoded stop, as `suggestedName` needs it: a short place label
    /// plus which country it's in (when known). `places` is in first-seen
    /// (chronological) order.
    struct PlaceStop {
        var name: String
        var country: String?
    }

    /// Builds a trip name from its geocoded stops, grouped by country —
    /// not a flat list of every city visited. The earlier version just
    /// joined place names ("I Municipio, Rome + 5 more"), which was
    /// accurate but not evocative, and for a multi-city single-country
    /// trip (Rome → Venice → Florence) read as a Rome trip with an
    /// afterthought rather than one Italy trip. Reported directly: "trips
    /// are still coming as cities instead of countries... combine".
    ///
    /// - One country, one city: "Rome, Italy".
    /// - One country, several cities: "Italy — Rome, Venice & Florence",
    ///   or "X Days in Italy" once there are too many cities to list
    ///   (reads better than a long comma chain).
    /// - Several countries: "Italy & France", or "Italy, France & 1 more"
    ///   beyond two.
    /// - No country data at all (geocoding failed/unresolved for every
    ///   stop, or a GPS-less trip): falls back to the previous date-range
    ///   name — this is the only case with no place data to work with.
    static func suggestedName(startDay: Date, endDay: Date, places: [PlaceStop] = []) -> String {
        let withCountry = places.filter { $0.country != nil }

        if !withCountry.isEmpty {
            var countryOrder: [String] = []
            var citiesByCountry: [String: [String]] = [:]
            for place in withCountry {
                guard let country = place.country else { continue }
                if citiesByCountry[country] == nil { countryOrder.append(country) }
                var cities = citiesByCountry[country] ?? []
                if !cities.contains(place.name) { cities.append(place.name) }
                citiesByCountry[country] = cities
            }

            if countryOrder.count == 1, let country = countryOrder.first {
                let cities = citiesByCountry[country] ?? []
                if cities.count <= 1 {
                    return cities.first.map { "\($0), \(country)" } ?? country
                }
                if cities.count <= 3 {
                    return "\(country) — \(joinedWithAmpersand(cities))"
                }
                let dayCount = Calendar.current.dateComponents([.day], from: startDay, to: endDay).day.map { $0 + 1 } ?? 1
                return "\(dayCount) Days in \(country)"
            }

            if countryOrder.count <= 2 {
                return joinedWithAmpersand(countryOrder)
            }
            return "\(countryOrder[0]), \(countryOrder[1]) + \(countryOrder.count - 2) more"
        }

        // No country data for any stop: fall back to a city-name-only
        // join (still better than nothing when geocoding resolved a name
        // but not a country), then the date range if there's truly
        // nothing.
        if let first = places.first?.name {
            if places.count > 1 {
                return "\(first) + \(places.count - 1) more"
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

    private static func joinedWithAmpersand(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " & " + last
    }
}
