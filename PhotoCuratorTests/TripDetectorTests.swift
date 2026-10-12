import XCTest
import CoreLocation
@testable import PhotoCurator

/// Trip boundaries come from day grouping, place segmentation and date gaps
/// together (PRD §10, full design) — a boundary forms on a silent gap OR a
/// large GPS jump between consecutive active days. See `TripDetector`.
final class TripDetectorTests: XCTestCase {

    private func record(_ id: String, daysFromEpoch: Int,
                        latitude: Double? = nil, longitude: Double? = nil) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.creationDate = Date(timeIntervalSince1970: 0)
            .addingTimeInterval(TimeInterval(daysFromEpoch * 86400 + 43200)) // noon, to avoid DST edges
        record.latitude = latitude
        record.longitude = longitude
        return record
    }

    func testSingleRunBelowMinGapStaysOneTrip() {
        var detector = TripDetector()
        detector.minGapDays = 3
        detector.minPhotosToQualify = 2

        // Days 0, 1, 2 (no gap) then day 4 (a 1-day gap) — still one trip
        // since the gap is well under the 3-day threshold.
        let records = [
            record("a", daysFromEpoch: 0), record("b", daysFromEpoch: 0),
            record("c", daysFromEpoch: 1), record("d", daysFromEpoch: 1),
            record("e", daysFromEpoch: 4), record("f", daysFromEpoch: 4)
        ]

        let candidates = detector.detect(in: records)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.photoIds.count, 6)
    }

    func testGapAtOrAboveThresholdSplitsIntoTwoTrips() {
        var detector = TripDetector()
        detector.minGapDays = 3
        detector.minPhotosToQualify = 2

        // Day 0 then day 5: a 4-day silent gap, at/above the 3-day threshold.
        let records = [
            record("a", daysFromEpoch: 0), record("b", daysFromEpoch: 0),
            record("c", daysFromEpoch: 5), record("d", daysFromEpoch: 5)
        ]

        let candidates = detector.detect(in: records)
        XCTAssertEqual(candidates.count, 2)
    }

    func testRunsBelowMinPhotosAreDropped() {
        var detector = TripDetector()
        detector.minGapDays = 3
        detector.minPhotosToQualify = 8

        let records = [record("a", daysFromEpoch: 0), record("b", daysFromEpoch: 0)]

        XCTAssertTrue(detector.detect(in: records).isEmpty)
    }

    func testPhotosWithNoCreationDateAreIgnored() {
        var detector = TripDetector()
        detector.minPhotosToQualify = 1
        let undateable = PhotoRecord(id: "no-date")   // creationDate left nil

        XCTAssertTrue(detector.detect(in: [undateable]).isEmpty)
    }

    func testHasAnyLocationReflectsAnyDayInRange() {
        var detector = TripDetector()
        detector.minPhotosToQualify = 1

        var located = record("a", daysFromEpoch: 0)
        located.latitude = 35.0
        located.longitude = 139.0
        let unlocated = record("b", daysFromEpoch: 0)

        let candidates = detector.detect(in: [located, unlocated])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates.first?.hasAnyLocation ?? false)
    }

    func testNoLocationAnywhereInRangeIsFalse() {
        var detector = TripDetector()
        detector.minPhotosToQualify = 1

        let candidates = detector.detect(in: [record("a", daysFromEpoch: 0)])
        XCTAssertFalse(candidates.first?.hasAnyLocation ?? true)
    }

    // MARK: Place-jump boundary (PRD §10, full design)

    /// A large GPS jump between consecutive active days splits a trip even
    /// with zero days of silence between them — the scenario a pure
    /// date-gap detector would miss entirely.
    func testLargePlaceJumpSplitsEvenWithNoDateGap() {
        var detector = TripDetector()
        detector.minGapDays = 3   // would normally require a 3-day gap
        detector.minPhotosToQualify = 1
        var settings = CuratorSettings.default
        settings.tripPlaceJumpDistance = 50_000   // 50km

        // Seoul, then consecutive day in Busan (~325km away), no date gap.
        let records = [
            record("a", daysFromEpoch: 0, latitude: 37.5665, longitude: 126.9780),
            record("b", daysFromEpoch: 1, latitude: 35.1796, longitude: 129.0756)
        ]

        let candidates = detector.detect(in: records, settings: settings)
        XCTAssertEqual(candidates.count, 2, "a large same-week location jump must start a new trip")
    }

    /// A small GPS move (same city) must not split a trip on its own.
    func testSmallPlaceMoveDoesNotSplit() {
        var detector = TripDetector()
        detector.minGapDays = 3
        detector.minPhotosToQualify = 1
        var settings = CuratorSettings.default
        settings.tripPlaceJumpDistance = 50_000

        // Two points a few km apart within Seoul.
        let records = [
            record("a", daysFromEpoch: 0, latitude: 37.5665, longitude: 126.9780),
            record("b", daysFromEpoch: 1, latitude: 37.5796, longitude: 126.9770)
        ]

        let candidates = detector.detect(in: records, settings: settings)
        XCTAssertEqual(candidates.count, 1)
    }

    /// Missing GPS on either side of a day boundary must never be read as a
    /// jump — there is nothing to measure, so detection falls back to the
    /// date-gap rule alone rather than guessing a split occurred.
    func testMissingGPSOnEitherSideNeverCountsAsAJump() {
        var detector = TripDetector()
        detector.minGapDays = 3
        detector.minPhotosToQualify = 1
        var settings = CuratorSettings.default
        settings.tripPlaceJumpDistance = 50_000

        let records = [
            record("a", daysFromEpoch: 0, latitude: 37.5665, longitude: 126.9780),
            record("b", daysFromEpoch: 1)   // no GPS at all
        ]

        let candidates = detector.detect(in: records, settings: settings)
        XCTAssertEqual(candidates.count, 1, "no measurable jump should not split the trip")
    }

    /// Segments are computed per active day and surfaced on the candidate,
    /// for the naming sheet to geocode.
    func testCandidateCarriesPerDaySegments() {
        var detector = TripDetector()
        detector.minPhotosToQualify = 1

        let records = [
            record("a", daysFromEpoch: 0, latitude: 37.5665, longitude: 126.9780),
            record("b", daysFromEpoch: 0, latitude: 37.5666, longitude: 126.9781)
        ]

        let candidates = detector.detect(in: records)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.segmentsByDay.values.flatMap { $0 }.count, 1,
                       "two close-together same-day photos should form one segment")
    }

    // MARK: Home exclusion (requirement: not everything is a trip)

    private func home(latitude: Double, longitude: Double, radius: Double = 50_000) -> HomeLocation {
        HomeLocation(name: "Home", latitude: latitude, longitude: longitude,
                    radius: radius, isAutoDetected: true, distinctDayCount: 40)
    }

    /// A run of days entirely at home must never be offered as a trip, no
    /// matter how many photos it has.
    func testEntirelyHomeDaysProduceNoTrip() {
        var detector = TripDetector()
        detector.minPhotosToQualify = 2

        let homeCoord = (latitude: 37.5665, longitude: 126.9780)
        let records = (0..<5).map { day in
            record("home-\(day)", daysFromEpoch: day, latitude: homeCoord.latitude, longitude: homeCoord.longitude)
        }
        let homes = [home(latitude: homeCoord.latitude, longitude: homeCoord.longitude)]

        XCTAssertTrue(detector.detect(in: records, homes: homes).isEmpty)
    }

    /// A real trip away from home is still detected once home days are
    /// excluded, even though nothing separates them by date gap alone.
    func testAwayDaysStillFormATripWithHomeDaysRemoved() {
        var detector = TripDetector()
        detector.minGapDays = 3
        detector.minPhotosToQualify = 2

        let homeCoord = (latitude: 37.5665, longitude: 126.9780)
        let awayCoord = (latitude: 35.1796, longitude: 129.0756)   // Busan, ~325km away
        let homes = [home(latitude: homeCoord.latitude, longitude: homeCoord.longitude)]

        let records = [
            record("h1", daysFromEpoch: 0, latitude: homeCoord.latitude, longitude: homeCoord.longitude),
            record("h2", daysFromEpoch: 1, latitude: homeCoord.latitude, longitude: homeCoord.longitude),
            record("t1", daysFromEpoch: 2, latitude: awayCoord.latitude, longitude: awayCoord.longitude),
            record("t2", daysFromEpoch: 3, latitude: awayCoord.latitude, longitude: awayCoord.longitude),
            record("h3", daysFromEpoch: 4, latitude: homeCoord.latitude, longitude: homeCoord.longitude)
        ]

        let candidates = detector.detect(in: records, homes: homes)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.photoIds.sorted(), ["t1", "t2"])
    }

    /// Home days between two away runs act as a boundary even when the
    /// silent-day count alone would not have crossed `minGapDays`.
    func testHomeDaysSeparateTwoTripsEvenBelowMinGap() {
        var detector = TripDetector()
        detector.minGapDays = 5   // deliberately high; the home days are what separates these
        detector.minPhotosToQualify = 1

        let homeCoord = (latitude: 37.5665, longitude: 126.9780)
        let tripA = (latitude: 35.1796, longitude: 129.0756)
        let tripB = (latitude: 33.4996, longitude: 126.5312)   // Jeju
        let homes = [home(latitude: homeCoord.latitude, longitude: homeCoord.longitude)]

        let records = [
            record("a", daysFromEpoch: 0, latitude: tripA.latitude, longitude: tripA.longitude),
            record("home", daysFromEpoch: 1, latitude: homeCoord.latitude, longitude: homeCoord.longitude),
            record("b", daysFromEpoch: 2, latitude: tripB.latitude, longitude: tripB.longitude)
        ]

        let candidates = detector.detect(in: records, homes: homes)
        XCTAssertEqual(candidates.count, 2, "a home day between two away days should split them into separate trips")
    }

    /// A day with no located photos at all cannot be classified as home —
    /// there is nothing to check against a radius — so it still
    /// participates in detection via the date-gap signal.
    func testDayWithNoGPSIsNeverClassifiedAsHome() {
        var detector = TripDetector()
        detector.minPhotosToQualify = 1
        let homes = [home(latitude: 37.5665, longitude: 126.9780)]

        let candidates = detector.detect(in: [record("a", daysFromEpoch: 0)], homes: homes)
        XCTAssertEqual(candidates.count, 1, "an unlocated day must not be silently dropped as home")
    }

    /// A day mostly spent away, with one home-radius photo along the way
    /// (e.g. an airport near home before departure), should still count as
    /// an away day — the majority rule, not "any home photo disqualifies".
    func testMajorityAwayDayIsNotHome() {
        var detector = TripDetector()
        detector.minPhotosToQualify = 1
        let homeCoord = (latitude: 37.5665, longitude: 126.9780)
        let awayCoord = (latitude: 35.1796, longitude: 129.0756)
        let homes = [home(latitude: homeCoord.latitude, longitude: homeCoord.longitude)]

        var mixed: [PhotoRecord] = []
        mixed.append(record("home-photo", daysFromEpoch: 0, latitude: homeCoord.latitude, longitude: homeCoord.longitude))
        for i in 0..<4 {
            mixed.append(record("away-\(i)", daysFromEpoch: 0, latitude: awayCoord.latitude, longitude: awayCoord.longitude))
        }

        let candidates = detector.detect(in: mixed, homes: homes)
        XCTAssertEqual(candidates.count, 1, "a day that is mostly away should still count as an away day")
    }
}

final class PlaceSegmenterTests: XCTestCase {

    private func record(_ id: String, minutesFromEpoch: Int,
                        latitude: Double?, longitude: Double?) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.creationDate = Date(timeIntervalSince1970: TimeInterval(minutesFromEpoch * 60))
        record.latitude = latitude
        record.longitude = longitude
        return record
    }

    /// PRD §10.2: a time gap beyond the threshold starts a new segment even
    /// at the same location.
    func testTimeGapSplitsSegment() {
        var settings = CuratorSettings.default
        settings.placeSegmentMaxTimeGap = 30 * 60
        let photos = [
            record("a", minutesFromEpoch: 0, latitude: 1, longitude: 1),
            record("b", minutesFromEpoch: 40, latitude: 1, longitude: 1)   // 40 min later
        ]
        let segments = PlaceSegmenter().segment(photos, settings: settings)
        XCTAssertEqual(segments.count, 2)
    }

    /// PRD §10.2: a distance beyond the threshold starts a new segment even
    /// with no time gap.
    func testDistanceSplitsSegment() {
        var settings = CuratorSettings.default
        settings.placeSegmentMaxDistance = 500
        let photos = [
            record("a", minutesFromEpoch: 0, latitude: 37.5665, longitude: 126.9780),
            record("b", minutesFromEpoch: 1, latitude: 37.6000, longitude: 127.0200)   // several km away
        ]
        let segments = PlaceSegmenter().segment(photos, settings: settings)
        XCTAssertEqual(segments.count, 2)
    }

    func testCloseInTimeAndSpaceStayOneSegment() {
        let settings = CuratorSettings.default
        let photos = [
            record("a", minutesFromEpoch: 0, latitude: 37.5665, longitude: 126.9780),
            record("b", minutesFromEpoch: 5, latitude: 37.5666, longitude: 126.9781)
        ]
        let segments = PlaceSegmenter().segment(photos, settings: settings)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.photoIds.count, 2)
    }

    /// Missing GPS on either side falls back to the time gap alone.
    func testMissingGPSFallsBackToTimeGap() {
        var settings = CuratorSettings.default
        settings.placeSegmentMaxTimeGap = 30 * 60
        let photos = [
            record("a", minutesFromEpoch: 0, latitude: nil, longitude: nil),
            record("b", minutesFromEpoch: 5, latitude: 37.5665, longitude: 126.9780)
        ]
        let segments = PlaceSegmenter().segment(photos, settings: settings)
        XCTAssertEqual(segments.count, 1)
    }

    func testCentroidOfEmptyLocationsIsNil() {
        XCTAssertNil(PlaceSegmenter.centroid(of: []))
    }

    func testCentroidAverages() {
        let locations = [
            CLLocation(latitude: 0, longitude: 0),
            CLLocation(latitude: 2, longitude: 2)
        ]
        let centroid = PlaceSegmenter.centroid(of: locations)
        XCTAssertEqual(centroid?.coordinate.latitude ?? -999, 1, accuracy: 0.0001)
        XCTAssertEqual(centroid?.coordinate.longitude ?? -999, 1, accuracy: 0.0001)
    }
}

final class TripModelTests: XCTestCase {
    func testSuggestedNameSingleDay() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let name = Trip.suggestedName(startDay: day, endDay: day)
        XCTAssertTrue(name.hasPrefix("Trip — "))
        XCTAssertFalse(name.contains("to"))
    }

    func testSuggestedNameRange() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86400 * 5)
        let name = Trip.suggestedName(startDay: start, endDay: end)
        XCTAssertTrue(name.contains("to"))
    }

    /// PRD §10.3: a single resolved place becomes the trip name outright.
    func testSuggestedNamePrefersSinglePlace() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let name = Trip.suggestedName(startDay: day, endDay: day, placeNames: ["Seoul, South Korea"])
        XCTAssertEqual(name, "Seoul, South Korea")
    }

    /// Multiple places collapse to "first + N more" so the name stays short.
    func testSuggestedNameCollapsesMultiplePlaces() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let name = Trip.suggestedName(startDay: day, endDay: day,
                                      placeNames: ["Seoul, South Korea", "Busan, South Korea"])
        XCTAssertEqual(name, "Seoul, South Korea + 1 more")
    }
}

final class HomeLocationDetectorTests: XCTestCase {

    private func record(_ id: String, daysFromEpoch: Int, latitude: Double, longitude: Double) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.creationDate = Date(timeIntervalSince1970: 0)
            .addingTimeInterval(TimeInterval(daysFromEpoch * 86400 + 43200))
        record.latitude = latitude
        record.longitude = longitude
        return record
    }

    /// The defining signal is day-spread, not photo count: a short, heavy
    /// trip must not outrank a long, sparse pattern of home life.
    func testDenseShortTripDoesNotOutrankSparseLongTermHome() {
        var settings = CuratorSettings.default
        settings.homeMinDistinctDays = 30

        var records: [PhotoRecord] = []
        // "Home": 1 photo/day across 40 distinct days.
        for day in 0..<40 {
            records.append(record("home-\(day)", daysFromEpoch: day, latitude: 37.5665, longitude: 126.9780))
        }
        // "Trip": 50 photos crammed into a single day, far away.
        for i in 0..<50 {
            records.append(record("trip-\(i)", daysFromEpoch: 100, latitude: 48.8566, longitude: 2.3522))
        }

        let candidates = HomeLocationDetector().detect(in: records, settings: settings)
        XCTAssertEqual(candidates.count, 1, "the one-day photo burst must not qualify as a second home")
        XCTAssertEqual(candidates.first?.dayCount, 40)
    }

    /// Below the minimum distinct-day bar, nothing qualifies as home.
    func testBelowMinDistinctDaysProducesNoCandidate() {
        var settings = CuratorSettings.default
        settings.homeMinDistinctDays = 30

        let records = (0..<10).map {
            record("p\($0)", daysFromEpoch: $0, latitude: 37.5665, longitude: 126.9780)
        }

        XCTAssertTrue(HomeLocationDetector().detect(in: records, settings: settings).isEmpty)
    }

    /// Two genuinely distant, independently long-term locations (e.g. two
    /// homes lived in over the years) both qualify, rather than merging
    /// into one or losing the weaker one.
    func testTwoDistantLongTermLocationsBothQualify() {
        var settings = CuratorSettings.default
        settings.homeMinDistinctDays = 30
        settings.homeRadius = 50_000

        var records: [PhotoRecord] = []
        for day in 0..<40 {
            records.append(record("seoul-\(day)", daysFromEpoch: day, latitude: 37.5665, longitude: 126.9780))
        }
        for day in 40..<80 {
            records.append(record("tokyo-\(day)", daysFromEpoch: day, latitude: 35.6762, longitude: 139.6503))
        }

        let candidates = HomeLocationDetector().detect(in: records, settings: settings)
        XCTAssertEqual(candidates.count, 2)
    }
}
