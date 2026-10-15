import XCTest
@testable import PhotoCurator

/// PRD §13: "No photo in Tier 3 is ever deleted by any tier button." This is
/// the second of the two independent guards (`TierAssigner` is the first):
/// even if a caller passed a bad set, the service itself refuses.
final class PhotoDeletionServiceTests: XCTestCase {

    private let service = PhotoDeletionService()

    func testRefusesWhenAnyRecordIsTier3() async {
        var protected = PhotoRecord(id: "keep-me")
        protected.tier = .tier3Protected
        protected.reason = .favorite

        var junk = PhotoRecord(id: "junk-1")
        junk.tier = .tier1
        junk.reason = .screenshot

        do {
            try await service.delete([protected, junk], cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRefusesWhenEveryRecordIsTier3() async {
        var a = PhotoRecord(id: "a"); a.tier = .tier3Protected
        var b = PhotoRecord(id: "b"); b.tier = .tier3Protected

        do {
            try await service.delete([a, b], cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 2)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testEmptyInputIsANoOp() async throws {
        try await service.delete([], cache: nil)   // must not throw
    }
}

/// `deleteTripExtras` is the one deliberate exception to "Tier 3 is never
/// deleted" — it must still refuse anything protected for a real reason
/// (favorite, album, edited, known person), accepting only the "nothing
/// flagged it either way" reasons (`.keep`, `.lowConfidence`,
/// `.specialLandscape`), even though every record passed in is Tier 3.
final class TripExtrasDeletionTests: XCTestCase {

    private let service = PhotoDeletionService()

    private func tier3(_ id: String, reason: TierReason) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.tier = .tier3Protected
        record.reason = reason
        return record
    }

    func testAcceptsOnlyUnprotectedReasons() async throws {
        let extras = [
            tier3("a", reason: .keep),
            tier3("b", reason: .lowConfidence),
            tier3("c", reason: .specialLandscape),
        ]
        try await service.deleteTripExtras(extras, cache: nil)   // must not throw
    }

    func testRefusesAFavoriteEvenInTheExtrasPath() async {
        let batch = [tier3("a", reason: .keep), tier3("fav", reason: .favorite)]
        do {
            try await service.deleteTripExtras(batch, cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRefusesAKnownPersonEvenInTheExtrasPath() async {
        let batch = [tier3("person", reason: .knownPerson)]
        do {
            try await service.deleteTripExtras(batch, cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Regression: a person who appears in only a few photos never clears
    /// `knownPersonMinPhotos`, so `TierAssigner` tags their photos plain
    /// `.keep`, not `.knownPerson` — this reported as "Extras showing
    /// photos with people in them". `hasPeople` must refuse these
    /// independent of reason.
    func testRefusesAnUnrecognizedPersonTaggedOnlyAsKeep() async {
        var withFace = tier3("has-a-face", reason: .keep)
        withFace.faceCount = 1
        do {
            try await service.deleteTripExtras([withFace], cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRefusesAPhotoWithOnlyABodyDetectedNoFace() async {
        var withBody = tier3("has-a-body", reason: .lowConfidence)
        withBody.bodyCount = 1
        do {
            try await service.deleteTripExtras([withBody], cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRefusesAnEditedPhotoEvenInTheExtrasPath() async {
        let batch = [tier3("edited", reason: .edited)]
        do {
            try await service.deleteTripExtras(batch, cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRefusesAnAlbumMemberEvenInTheExtrasPath() async {
        let batch = [tier3("album", reason: .inUserAlbum)]
        do {
            try await service.deleteTripExtras(batch, cache: nil)
            XCTFail("expected attemptedProtectedDeletion to be thrown")
        } catch PhotoDeletionService.DeletionError.attemptedProtectedDeletion(let count) {
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testEmptyInputIsANoOp() async throws {
        try await service.deleteTripExtras([], cache: nil)   // must not throw
    }
}

/// `LibraryScanner.filterExtras` is the selection logic behind the
/// trip-scoped "Extra Photos" bucket: Tier 3, not chosen for the book, and
/// not protected for a real reason.
final class FilterExtrasTests: XCTestCase {

    private func tier3(_ id: String, reason: TierReason) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.tier = .tier3Protected
        record.reason = reason
        return record
    }

    private func notTier3(_ id: String, tier: Tier, reason: TierReason) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.tier = tier
        record.reason = reason
        return record
    }

    func testIncludesUnchosenKeepLowConfidenceAndSpecialLandscape() {
        let photos = [
            tier3("a", reason: .keep),
            tier3("b", reason: .lowConfidence),
            tier3("c", reason: .specialLandscape),
        ]
        let result = LibraryScanner.filterExtras(photos, chosenIds: [])
        XCTAssertEqual(Set(result.map(\.id)), ["a", "b", "c"])
    }

    func testExcludesChosenPhotosEvenIfOtherwiseEligible() {
        let photos = [tier3("a", reason: .keep), tier3("b", reason: .keep)]
        let result = LibraryScanner.filterExtras(photos, chosenIds: ["a"])
        XCTAssertEqual(result.map(\.id), ["b"])
    }

    func testExcludesFavoritesAlbumMembersEditsAndKnownPeople() {
        let photos = [
            tier3("fav", reason: .favorite),
            tier3("album", reason: .inUserAlbum),
            tier3("edited", reason: .edited),
            tier3("person", reason: .knownPerson),
        ]
        let result = LibraryScanner.filterExtras(photos, chosenIds: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testExcludesNonTier3PhotosRegardlessOfReason() {
        // Defensive: Tier 1/2 photos should never appear here even if a
        // reason happened to collide with an eligible one.
        let photos = [notTier3("junk", tier: .tier1, reason: .keep)]
        let result = LibraryScanner.filterExtras(photos, chosenIds: [])
        XCTAssertTrue(result.isEmpty)
    }

    /// Regression: an infrequently-seen person has a detected face but
    /// never clears `knownPersonMinPhotos`, so `TierAssigner` tags the
    /// photo plain `.keep` rather than `.knownPerson` — `hasPeople` must
    /// still keep it out of the extras bucket regardless of reason.
    func testExcludesAnyPhotoWithADetectedFaceEvenIfTaggedKeep() {
        var withFace = tier3("has-a-face", reason: .keep)
        withFace.faceCount = 1
        let result = LibraryScanner.filterExtras([withFace], chosenIds: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testExcludesAnyPhotoWithADetectedBodyEvenIfTaggedLowConfidence() {
        var withBody = tier3("has-a-body", reason: .lowConfidence)
        withBody.bodyCount = 1
        let result = LibraryScanner.filterExtras([withBody], chosenIds: [])
        XCTAssertTrue(result.isEmpty)
    }
}

/// PRD §6: rescue and "Keep all" must never let a photo re-enter a
/// deletable tier, and a deletion must shrink `records` without a rescan.
final class LibraryScannerTierActionsTests: XCTestCase {

    @MainActor
    func testPhotosInFiltersByTier() {
        let scanner = LibraryScanner()
        // `records` is private(set); this test only exercises the public
        // `photos(in:)` surface against the default empty state.
        XCTAssertEqual(scanner.photos(in: .tier1).count, 0)
        XCTAssertEqual(scanner.photos(in: .tier2).count, 0)
        XCTAssertEqual(scanner.photos(in: .tier3Protected).count, 0)
    }
}
