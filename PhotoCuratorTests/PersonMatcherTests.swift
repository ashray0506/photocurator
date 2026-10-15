import XCTest
@testable import PhotoCurator

/// `FeaturePrintStore.distance` needs a real archived `VNFeaturePrintObservation`
/// to return anything but nil — same constraint the existing
/// `FaceClusterer` tests work around by passing `featurePrint: nil`
/// (`ScoringAndClusteringTests.swift`). These tests cover the bookkeeping
/// around matching (new-person creation, stat propagation, thumbnail
/// stability) rather than the match/no-match decision itself, which needs
/// real Vision inference to exercise meaningfully.
final class PersonMatcherTests: XCTestCase {

    func testEmptyInputProducesNoMatches() {
        let matches = PersonMatcher().match(clusterPrints: [:],
                                            clusterStats: [:],
                                            thumbnailPhotoId: [:],
                                            existingPeople: [],
                                            settings: .default)
        XCTAssertTrue(matches.isEmpty)
    }

    /// With no existing people (or print data that can never match, same
    /// effect), every cluster becomes a brand-new `Person`.
    func testUnmatchableClustersEachBecomeANewPerson() {
        let clusterPrints: [Int: Data] = [1: Data([0x01]), 2: Data([0x02])]
        let matches = PersonMatcher().match(clusterPrints: clusterPrints,
                                            clusterStats: [:],
                                            thumbnailPhotoId: [1: "photo-a", 2: "photo-b"],
                                            existingPeople: [],
                                            settings: .default)
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.allSatisfy(\.isNewPerson))
        XCTAssertEqual(Set(matches.map(\.clusterId)), [1, 2])
    }

    func testNewPersonCarriesStatsAndThumbnail() {
        let matches = PersonMatcher().match(
            clusterPrints: [7: Data([0xAA])],
            clusterStats: [7: (photoCount: 12, dayCount: 3)],
            thumbnailPhotoId: [7: "best-photo"],
            existingPeople: [],
            settings: .default
        )
        guard let match = matches.first else { return XCTFail("expected one match") }
        XCTAssertEqual(match.person.photoCount, 12)
        XCTAssertEqual(match.person.dayCount, 3)
        XCTAssertEqual(match.person.thumbnailPhotoId, "best-photo")
        XCTAssertNil(match.person.name, "a freshly created person has no name yet")
    }

    /// A cluster with no feature print at all is skipped outright rather
    /// than becoming a person with a garbage/empty identity — mirrors
    /// `FaceClusterer`'s own "no usable print means do nothing" stance.
    func testMissingPrintProducesNoMatchForThatCluster() {
        let matches = PersonMatcher().match(clusterPrints: [:],
                                            clusterStats: [3: (5, 2)],
                                            thumbnailPhotoId: [3: "photo-c"],
                                            existingPeople: [],
                                            settings: .default)
        XCTAssertTrue(matches.isEmpty)
    }

    func testDisplayNameFallsBackToGenericPlaceholderWhenUnnamed() {
        let person = Person(photoCount: 42)
        XCTAssertEqual(person.displayName, "Person seen 42 times")
    }

    func testDisplayNameUsesRealNameWhenSet() {
        var person = Person(photoCount: 42)
        person.name = "Alex"
        XCTAssertEqual(person.displayName, "Alex")
    }

    func testDisplayNameSingularForOnePhoto() {
        let person = Person(photoCount: 1)
        XCTAssertEqual(person.displayName, "Person seen 1 time")
    }

    // MARK: Multi-print accumulation (the actual fix for "splits into many")

    /// A brand-new person starts with exactly the one print that created
    /// them, not an empty array — otherwise the very next rescan would
    /// have nothing to match against and immediately fork into a second
    /// person.
    func testNewPersonStartsWithExactlyOnePrint() {
        let matches = PersonMatcher().match(clusterPrints: [1: Data([0x01])],
                                            clusterStats: [:],
                                            thumbnailPhotoId: [:],
                                            existingPeople: [],
                                            settings: .default)
        XCTAssertEqual(matches.first?.person.representativeFeaturePrints, [Data([0x01])])
    }

    /// Garbage/undecodable print data (as used throughout this file,
    /// since a real `VNFeaturePrintObservation` needs live Vision
    /// inference) never decodes to a distance, so two people can never
    /// spuriously merge from it — confirms the matcher fails closed
    /// (treats "can't tell" as "different people") rather than open.
    func testUndecodablePrintsNeverCauseAMatch() {
        let existing = [Person(representativeFeaturePrints: [Data([0x01])])]
        let matches = PersonMatcher().match(clusterPrints: [1: Data([0x02])],
                                            clusterStats: [:],
                                            thumbnailPhotoId: [:],
                                            existingPeople: existing,
                                            settings: .default)
        XCTAssertEqual(matches.first?.isNewPerson, true,
                       "undecodable prints must never be treated as a match")
    }

    func testOldSinglePrintFieldStillDecodesIntoTheNewArray() throws {
        // Simulates a `Person` saved before `representativeFeaturePrints`
        // existed, when the field was a single `Data?` named
        // `representativeFeaturePrint` — the exact shape a pre-migration
        // persisted row has.
        let legacyJSON = """
        {"id":"abc","representativeFeaturePrint":"AQ==","photoCount":5,"dayCount":2}
        """
        let person = try JSONDecoder().decode(Person.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(person.representativeFeaturePrints, [Data([0x01])])
        XCTAssertEqual(person.photoCount, 5)
    }
}
