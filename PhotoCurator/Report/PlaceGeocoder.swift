import Foundation
import CoreLocation
import os

/// Reverse-geocodes a place segment's centroid to a human name (PRD §10.3).
///
/// `CLGeocoder` is rate-limited by Apple and the same handful of places get
/// visited repeatedly within a trip (a hotel, a station), so results are
/// cached by a rounded coordinate key for the lifetime of the app. The cache
/// is intentionally in-memory only: place names are cheap to regenerate and
/// persisting them would mean invalidation logic for no real benefit.
///
/// `CLGeocoder.reverseGeocodeLocation` is deprecated on macOS 26 in favour of
/// `MKReverseGeocodingRequest`, which is 26.0+ only. This project's
/// deployment target is 15.0, so the deprecated API stays in use here
/// (it still functions) rather than forking two implementations for a
/// secondary, best-effort feature.
actor PlaceGeocoder {

    enum PlaceName {
        case resolved(String)
        case unresolved   // geocoding failed or returned nothing usable
    }

    private let geocoder = CLGeocoder()
    private var cache: [String: PlaceName] = [:]
    private let log = Logger(subsystem: "app.photocurator", category: "geocoder")

    /// Rounds to ~1km so nearby segments share a cache entry and a lookup.
    private func cacheKey(for location: CLLocation) -> String {
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }

    /// A short, book-friendly name: "Neighbourhood, City" when both are
    /// available, falling back to whichever piece of the placemark exists.
    func name(for location: CLLocation) async -> PlaceName {
        let key = cacheKey(for: location)
        if let cached = cache[key] { return cached }

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                cache[key] = .unresolved
                return .unresolved
            }
            let name = Self.formattedName(from: placemark)
            let result: PlaceName = name.map { .resolved($0) } ?? .unresolved
            cache[key] = result
            return result
        } catch {
            log.error("Reverse geocode failed: \(error.localizedDescription)")
            // Not cached: a transient network hiccup should not permanently
            // poison this coordinate for the rest of the session.
            return .unresolved
        }
    }

    /// Resolves names for several locations with a small concurrency cap, so
    /// a trip with many segments does not fire dozens of simultaneous
    /// geocoding requests at once (Apple's rate limiter would just queue or
    /// fail them).
    func names(for locations: [CLLocation]) async -> [PlaceName] {
        var results = [PlaceName](repeating: .unresolved, count: locations.count)
        let concurrency = 3
        var index = 0
        while index < locations.count {
            let end = min(index + concurrency, locations.count)
            await withTaskGroup(of: (Int, PlaceName).self) { group in
                for i in index..<end {
                    group.addTask { (i, await self.name(for: locations[i])) }
                }
                for await (i, name) in group { results[i] = name }
            }
            index = end
        }
        return results
    }

    private static func formattedName(from placemark: CLPlacemark) -> String? {
        let neighbourhood = placemark.subLocality ?? placemark.name
        let city = placemark.locality ?? placemark.administrativeArea ?? placemark.country

        if let neighbourhood, let city, neighbourhood != city {
            return "\(neighbourhood), \(city)"
        }
        return city ?? neighbourhood ?? placemark.country
    }
}
