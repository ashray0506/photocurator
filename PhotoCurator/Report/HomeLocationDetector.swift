import Foundation
import CoreLocation
import os

/// Finds home locations from GPS density across the whole library.
///
/// The distinguishing signal is **spread over time, not photo count**: a
/// single two-week vacation can produce more photos than months of home life
/// put together, but home life shows up on far more *distinct days* across a
/// much longer span. A location is a home candidate only when photos near it
/// appear on at least `settings.homeMinDistinctDays` separate days — a trip,
/// however photo-heavy, essentially never clears that bar on its own.
///
/// Approach: snap every located photo to a coarse grid cell (~`homeRadius`
/// sized), rank cells by distinct-day count, then merge nearby qualifying
/// cells into one home so a home near a cell boundary doesn't get split into
/// two half-strength candidates.
struct HomeLocationDetector: Sendable {

    private let log = Logger(subsystem: "app.photocurator", category: "home")

    func detect(in records: [PhotoRecord], settings: CuratorSettings) -> [(location: CLLocation, dayCount: Int)] {
        let calendar = Calendar.current

        // Grid cell size in degrees, approximated from the home radius.
        // 1 degree of latitude is ~111km everywhere; longitude varies with
        // latitude, but this is only used to seed candidate centroids that
        // get refined by an actual CLLocation distance check below, so the
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

        // Candidate cells: enough distinct days to look like home, not a trip.
        let candidates = daysByCell
            .filter { $0.value.count >= settings.homeMinDistinctDays }
            .map { (key: $0.key, dayCount: $0.value.count) }
            .sorted { $0.dayCount > $1.dayCount }

        guard !candidates.isEmpty else {
            log.notice("No home candidates: no location cluster reached \(settings.homeMinDistinctDays) distinct days")
            return []
        }

        // Merge candidate cells that are close together (adjacent grid cells
        // around the same real-world home) into one location, centroid-
        // weighted and day-counts combined, strongest first so a dominant
        // home absorbs its neighbours rather than the reverse.
        var merged: [(location: CLLocation, dayCount: Int)] = []
        var consumed = Set<CellKey>()

        for candidate in candidates {
            guard !consumed.contains(candidate.key) else { continue }
            let centroid = PlaceSegmenter.centroid(of: locationsByCell[candidate.key] ?? [])
            guard let centroid else { continue }

            var groupLocations = locationsByCell[candidate.key] ?? []
            var groupDays = daysByCell[candidate.key] ?? []
            consumed.insert(candidate.key)

            for other in candidates where !consumed.contains(other.key) {
                guard let otherCentroid = PlaceSegmenter.centroid(of: locationsByCell[other.key] ?? []) else { continue }
                if centroid.distance(from: otherCentroid) <= settings.homeRadius {
                    groupLocations.append(contentsOf: locationsByCell[other.key] ?? [])
                    groupDays.formUnion(daysByCell[other.key] ?? [])
                    consumed.insert(other.key)
                }
            }

            guard let finalCentroid = PlaceSegmenter.centroid(of: groupLocations) else { continue }
            merged.append((finalCentroid, groupDays.count))
        }

        let result = merged.sorted { $0.dayCount > $1.dayCount }
        log.notice("Detected \(result.count) home candidate(s) from \(candidates.count) qualifying grid cell(s)")
        return result
    }
}
