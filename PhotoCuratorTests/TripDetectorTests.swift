import XCTest
@testable import PhotoCurator

/// Trip boundaries come from date gaps alone (not GPS) because this app's
/// target library can have almost no location data — see PRD §10 vs. the
/// adapted design in `TripDetector`.
final class TripDetectorTests: XCTestCase {

    private func record(_ id: String, daysFromEpoch: Int) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.creationDate = Date(timeIntervalSince1970: 0)
            .addingTimeInterval(TimeInterval(daysFromEpoch * 86400 + 43200)) // noon, to avoid DST edges
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
}
