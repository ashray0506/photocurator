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
        /// `name` is the fuller, neighbourhood-aware display string
        /// ("I Municipio, Rome") — good for a day page's place label.
        /// `city` and `country` are kept separate from it, not folded in:
        /// trip naming needs "what CITY is this" independent of
        /// neighbourhood detail (a trip name built from `name` alone
        /// degraded to neighbourhood level — "I Municipio, Rome + 5
        /// more" — which is more precise than useful; reported directly:
        /// "minimum should be city"), and "what COUNTRY is this" to
        /// combine same-country stops. See `Trip.suggestedName`.
        case resolved(name: String, city: String?, country: String?)
        case unresolved   // geocoding failed or returned nothing usable
    }

    private let geocoder = CLGeocoder()
    private var cache: [String: PlaceName] = [:]
    private let log = Logger(subsystem: "app.photocurator", category: "geocoder")

    /// Trip/home detection can need dozens of lookups in one pass. On a
    /// machine where the system geocoding service (`geod`) never actually
    /// responds, paying the 5s timeout for every single one serialises into
    /// minutes of a visibly stuck UI. After a few consecutive timeouts in a
    /// row, stop trying for the rest of this `PlaceGeocoder`'s lifetime
    /// (one scan session) and fall back to date-range names instantly —
    /// a fresh app launch gets a fresh attempt, in case it was transient.
    private var consecutiveTimeouts = 0
    private let maxConsecutiveTimeouts = 3

    /// Rounds to ~1km so nearby segments share a cache entry and a lookup.
    private func cacheKey(for location: CLLocation) -> String {
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }

    /// A short, book-friendly name: "Neighbourhood, City" when both are
    /// available, falling back to whichever piece of the placemark exists.
    ///
    /// Uses the completion-handler API wrapped in our own continuation,
    /// not `CLGeocoder`'s `async` overload: that overload has been observed
    /// to leak its continuation (logged by the runtime as "SWIFT TASK
    /// CONTINUATION MISUSE... leaked its continuation without resuming it")
    /// on a sandboxed macOS app, hanging every caller awaiting it forever —
    /// which silently broke home-location and trip detection (both depend
    /// on geocoding completing). A 5s timeout race guards against the
    /// completion handler itself never firing for the same underlying
    /// reason.
    func name(for location: CLLocation) async -> PlaceName {
        let key = cacheKey(for: location)
        if let cached = cache[key] { return cached }

        guard consecutiveTimeouts < maxConsecutiveTimeouts else {
            return .unresolved
        }

        // The timeout task is `Task.detached`, not a plain child task: a
        // child task inherits this method's actor isolation, so if it ran
        // as one it could queue behind a reverseGeocode call stuck forever
        // on the same actor's serial executor and never actually fire.
        // Detaching guarantees it is scheduled independently on the
        // cooperative thread pool regardless of what the actor is doing.
        let geocodeTask = Task { await reverseGeocode(location) }
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            geocodeTask.cancel()
        }
        let result = await geocodeTask.value
        let timedOut = geocodeTask.isCancelled
        timeoutTask.cancel()

        if timedOut {
            consecutiveTimeouts += 1
            if consecutiveTimeouts == maxConsecutiveTimeouts {
                log.notice("Reverse geocoding timed out \(self.maxConsecutiveTimeouts) times in a row; disabling it for the rest of this session.")
            }
        } else {
            consecutiveTimeouts = 0
        }

        cache[key] = result
        return result
    }

    /// `CLGeocoder`'s completion handler has been observed to go silent
    /// forever on this system (confirmed in practice via Console: no
    /// success, no error, indefinitely — the actual root cause this whole
    /// continuation-based rewrite exists to contain; see the `name(for:)`
    /// doc comment). `withTaskCancellationHandler` resumes the continuation
    /// itself the moment the surrounding task is cancelled, rather than
    /// relying on `cancelGeocode()` triggering the handler (it may not);
    /// `ResumeOnce` guards against a double-resume if a late completion
    /// call ever does arrive after that.
    private func reverseGeocode(_ location: CLLocation) async -> PlaceName {
        let box = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PlaceName, Never>) in
                box.set(continuation)
                geocoder.reverseGeocodeLocation(location) { placemarks, error in
                    if let error {
                        self.log.error("Reverse geocode failed: \(error.localizedDescription)")
                        box.resume(.unresolved)
                        return
                    }
                    guard let placemark = placemarks?.first else {
                        box.resume(.unresolved)
                        return
                    }
                    let name = Self.formattedName(from: placemark)
                    let city = placemark.locality ?? placemark.administrativeArea
                    box.resume(name.map { .resolved(name: $0, city: city, country: placemark.country) } ?? .unresolved)
                }
            }
        } onCancel: {
            // Not `geocoder.cancelGeocode()`: that would touch the
            // actor-isolated `geocoder` property from this non-isolated
            // handler, which Swift 6 rejects (`CLGeocoder` isn't Sendable).
            // Resuming here is what actually unblocks the caller; the
            // underlying CLGeocoder request is simply left to finish (or
            // never finish) on its own and its result discarded via
            // `ResumeOnce`.
            box.resume(.unresolved)
        }
    }

    /// Delivers a `PlaceName` to whichever continuation is registered,
    /// exactly once, from whichever of (completion handler, cancellation
    /// handler) fires first. Both can run on arbitrary threads/queues
    /// concurrently with each other, so this needs its own lock rather
    /// than actor isolation (the cancellation handler in particular is
    /// not actor-isolated).
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PlaceName, Never>?

        func set(_ continuation: CheckedContinuation<PlaceName, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ value: PlaceName) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
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
