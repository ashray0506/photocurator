import XCTest
@testable import PhotoCurator

/// `deleteSmartSelection` is the riskiest new delete path this session:
/// unlike `deleteTripExtras` (confined to one trip) it can touch any
/// tier across the whole library, so its safety floor gets the most
/// direct test coverage — both the query-time filter (`SmartDeleteQuery`)
/// and the independent delete-time guard
/// (`PhotoDeletionService.deleteSmartSelection`) are checked separately,
/// matching how the two are deliberately not sharing one check.
final class SmartDeleteQueryTests: XCTestCase {

    private func record(_ id: String, tier: Tier, reason: TierReason,
                        faceCount: Int = 0, bodyCount: Int = 0,
                        faceClusterIds: [Int] = [], creationDate: Date? = nil,
                        isScreenshot: Bool = false) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.tier = tier
        record.reason = reason
        // A real PhotoRecord always has faceCount > 0 when faceClusterIds
        // is non-empty (clustering only assigns a cluster to a detected
        // face) — keep the fixture consistent with that, since `hasPeople`
        // reads `faceCount`, not `faceClusterIds`.
        record.faceCount = faceClusterIds.isEmpty ? faceCount : max(faceCount, 1)
        record.bodyCount = bodyCount
        record.faceClusterIds = faceClusterIds
        record.creationDate = creationDate
        record.media.isScreenshot = isScreenshot
        return record
    }

    // MARK: .noFace

    func testNoFaceRuleMatchesPhotosWithoutAnyDetectedFaceOrBody() {
        let withFace = record("a", tier: .tier2, reason: .nearDuplicate, faceCount: 1)
        let withoutFace = record("b", tier: .tier2, reason: .nearDuplicate)
        let query = SmartDeleteQuery(rules: [.noFace])
        let matches = query.matchingPhotos(in: [withFace, withoutFace], personIdByClusterId: [:])
        XCTAssertEqual(matches.map(\.id), ["b"])
    }

    // MARK: .faceNotIn

    func testFaceNotInMatchesAFaceOutsideTheSelection() {
        let stranger = record("stranger", tier: .tier2, reason: .strangerFocused, faceClusterIds: [1])
        let selected = record("selected", tier: .tier2, reason: .strangerFocused, faceClusterIds: [2])
        let noFaceAtAll = record("none", tier: .tier2, reason: .strangerFocused)
        let mapping = [1: "person-stranger", 2: "person-selected"]

        let query = SmartDeleteQuery(rules: [.faceNotIn(personIds: ["person-selected"])])
        let matches = query.matchingPhotos(in: [stranger, selected, noFaceAtAll], personIdByClusterId: mapping)

        XCTAssertEqual(matches.map(\.id), ["stranger"],
                       "a photo with a face in the selection, or no face at all, must not match")
    }

    // MARK: .inTier

    func testInTierMatchesOnlyThatTier() {
        let tier1 = record("a", tier: .tier1, reason: .screenshot)
        let tier2 = record("b", tier: .tier2, reason: .nearDuplicate)
        let query = SmartDeleteQuery(rules: [.inTier(.tier1)])
        let matches = query.matchingPhotos(in: [tier1, tier2], personIdByClusterId: [:])
        XCTAssertEqual(matches.map(\.id), ["a"])
    }

    // MARK: .olderThan

    func testOlderThanMatchesByAge() {
        let old = record("old", tier: .tier2, reason: .nearDuplicate,
                         creationDate: Date().addingTimeInterval(-400 * 86400))
        let recent = record("recent", tier: .tier2, reason: .nearDuplicate,
                            creationDate: Date().addingTimeInterval(-10 * 86400))
        let query = SmartDeleteQuery(rules: [.olderThan(days: 365)])
        let matches = query.matchingPhotos(in: [old, recent], personIdByClusterId: [:])
        XCTAssertEqual(matches.map(\.id), ["old"])
    }

    // MARK: Rules AND together

    func testMultipleRulesAreCombinedWithAnd() {
        let matchesBoth = record("both", tier: .tier2, reason: .nearDuplicate,
                                 creationDate: Date().addingTimeInterval(-400 * 86400))
        let onlyOld = record("only-old", tier: .tier3Protected, reason: .keep,
                             creationDate: Date().addingTimeInterval(-400 * 86400))
        let query = SmartDeleteQuery(rules: [.noFace, .inTier(.tier2), .olderThan(days: 365)])
        let matches = query.matchingPhotos(in: [matchesBoth, onlyOld], personIdByClusterId: [:])
        XCTAssertEqual(matches.map(\.id), ["both"])
    }

    // MARK: Safety floor — the query layer must never surface a real keeper

    func testQueryNeverSurfacesAFavoriteEvenIfRulesWouldOtherwiseMatch() {
        let favorite = record("fav", tier: .tier3Protected, reason: .favorite)
        let query = SmartDeleteQuery(rules: [.noFace])
        let matches = query.matchingPhotos(in: [favorite], personIdByClusterId: [:])
        XCTAssertTrue(matches.isEmpty)
    }

    func testQueryNeverSurfacesAKnownPersonPhoto() {
        let known = record("known", tier: .tier3Protected, reason: .knownPerson)
        let query = SmartDeleteQuery(rules: [.noFace])
        let matches = query.matchingPhotos(in: [known], personIdByClusterId: [:])
        XCTAssertTrue(matches.isEmpty)
    }

    func testQueryNeverSurfacesATier3PhotoWithADetectedFaceEvenTaggedKeep() {
        // Same reported-bug shape as Extras: an infrequently-seen person
        // has a detected face but reason `.keep`, not `.knownPerson`.
        let unrecognizedPerson = record("b", tier: .tier3Protected, reason: .keep, faceCount: 1)
        let query = SmartDeleteQuery(rules: [.inTier(.tier3Protected)])
        let matches = query.matchingPhotos(in: [unrecognizedPerson], personIdByClusterId: [:])
        XCTAssertTrue(matches.isEmpty)
    }

    func testQueryAllowsOrdinaryTier1Tier2DeletionEvenWithAFace() {
        // Unlike Tier 3, Tier 1/2 photos with a face are already normal
        // deletion candidates elsewhere in the app (e.g. strangerFocused)
        // — Smart Delete must not be MORE restrictive than that.
        let strangerJunk = record("a", tier: .tier2, reason: .strangerFocused, faceCount: 1)
        let query = SmartDeleteQuery(rules: [.inTier(.tier2)])
        let matches = query.matchingPhotos(in: [strangerJunk], personIdByClusterId: [:])
        XCTAssertEqual(matches.map(\.id), ["a"])
    }
}

/// The delete-time guard, independent of whatever `SmartDeleteQuery` already
/// filtered — mirrors `TripExtrasDeletionTests`' structure for the same
/// reason: a caller passing the wrong set must still be refused here.
final class SmartDeleteServiceTests: XCTestCase {

    private let service = PhotoDeletionService()

    private func record(_ id: String, tier: Tier, reason: TierReason, faceCount: Int = 0) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.tier = tier
        record.reason = reason
        record.faceCount = faceCount
        return record
    }

    func testAcceptsOrdinaryTier1AndTier2Deletion() async throws {
        let batch = [
            record("a", tier: .tier1, reason: .screenshot),
            record("b", tier: .tier2, reason: .nearDuplicate),
        ]
        try await service.deleteSmartSelection(batch, cache: nil)   // must not throw
    }

    func testAcceptsUnprotectedTier3Reasons() async throws {
        let batch = [
            record("a", tier: .tier3Protected, reason: .keep),
            record("b", tier: .tier3Protected, reason: .lowConfidence),
            record("c", tier: .tier3Protected, reason: .specialLandscape),
        ]
        try await service.deleteSmartSelection(batch, cache: nil)   // must not throw
    }

    func testRefusesAFavorite() async {
        let batch = [record("fav", tier: .tier3Protected, reason: .favorite)]
        do {
            try await service.deleteSmartSelection(batch, cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRefusesAKnownPerson() async {
        let batch = [record("person", tier: .tier3Protected, reason: .knownPerson)]
        do {
            try await service.deleteSmartSelection(batch, cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRefusesATier3PhotoWithADetectedFaceEvenTaggedKeep() async {
        let batch = [record("b", tier: .tier3Protected, reason: .keep, faceCount: 1)]
        do {
            try await service.deleteSmartSelection(batch, cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testEmptyInputIsANoOp() async throws {
        try await service.deleteSmartSelection([], cache: nil)   // must not throw
    }
}
