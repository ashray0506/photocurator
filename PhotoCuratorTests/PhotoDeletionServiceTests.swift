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
