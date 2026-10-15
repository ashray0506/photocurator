import Foundation
import Photos
import os

/// The only place in the app that may remove photos (PRD §6, §9).
///
/// Two independent guards back the "Tier 3 is never deleted" invariant:
/// 1. `TierAssigner` never assigns Tier 3 to anything deletion touches.
/// 2. This service additionally refuses, at the call site, to delete any
///    identifier whose current record says Tier 3. A caller passing the wrong
///    set is a bug; this makes that bug a thrown error instead of a loss.
final class PhotoDeletionService: Sendable {

    enum DeletionError: Error, LocalizedError {
        case attemptedProtectedDeletion(count: Int)
        case photoKitFailed(Error)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .attemptedProtectedDeletion(let count):
                return "Refused to delete \(count) protected photo(s). This should not happen — please report it."
            case .photoKitFailed(let error):
                return "Photos could not complete the deletion: \(error.localizedDescription)"
            case .cancelled:
                return "Deletion was cancelled. No photos were removed."
            }
        }
    }

    private let log = Logger(subsystem: "app.photocurator", category: "deletion")

    /// Batch size for PHAssetChangeRequest.deleteAssets (PRD §6: "in batches").
    /// Keeps a single system confirmation sheet responsive at tier sizes in
    /// the tens of thousands.
    private let batchSize = 2000

    /// Deletes every record in `records`, provided none is Tier 3.
    ///
    /// - Logs identifiers and reasons to the cache **before** calling
    ///   PhotoKit (PRD §9.5), so a crash mid-batch still leaves a record of
    ///   what was requested.
    /// - Calls `PHPhotoLibrary.performChanges` with
    ///   `PHAssetChangeRequest.deleteAssets`, which moves assets to Recently
    ///   Deleted; the app never empties it (PRD §9.4) and has no code path
    ///   that could.
    /// - Removes the deleted rows from the analysis cache so they do not
    ///   reappear as stale entries on the next scan.
    func delete(_ records: [PhotoRecord], cache: AnalysisCache?,
               progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        guard !records.isEmpty else { return }

        let protectedCount = records.filter { $0.tier == .tier3Protected }.count
        guard protectedCount == 0 else {
            log.error("Refused to delete \(protectedCount) Tier 3 record(s)")
            throw DeletionError.attemptedProtectedDeletion(count: protectedCount)
        }

        // Group by (tier, reason) so the log entries are accurate per photo
        // rather than one blanket reason for a mixed batch.
        var byReason: [TierReason: [PhotoRecord]] = [:]
        for record in records { byReason[record.reason, default: []].append(record) }
        for (reason, group) in byReason {
            guard let tier = group.first?.tier else { continue }
            try? cache?.logDeletion(ids: group.map(\.id), tier: tier, reason: reason)
        }

        let ids = records.map(\.id)
        var deletedSoFar = 0

        for batch in ids.chunked(into: batchSize) {
            try Task.checkCancellation()
            try await deleteBatch(batch)
            deletedSoFar += batch.count
            progress?(deletedSoFar, ids.count)
        }

        try? cache?.removePhotoRows(ids: ids)
        log.notice("Deleted \(ids.count) photos across \(byReason.count) reason group(s)")
    }

    /// Deletes Tier 3 "extras" — survivors a trip's book did not choose and
    /// that are protected only by default, not for a real reason. This is
    /// the one deliberate exception to "Tier 3 is never deleted": it still
    /// refuses anything whose reason is a genuine protection (favorite, in
    /// an album, edited, known person) even if the caller's bucket is
    /// wrong, so a bug upstream (e.g. in `LibraryScanner.unselectedExtras`)
    /// cannot delete a real keeper — only the `.keep` / `.lowConfidence` /
    /// `.specialLandscape` "nothing flagged it either way" reasons are ever
    /// accepted here. Everything else about the call (logging before
    /// PhotoKit, batching, cache row removal) matches `delete(_:cache:)`.
    ///
    /// Also independently refuses any photo with a detected face or body
    /// (`hasPeople`), not just ones tagged `.knownPerson`: `TierAssigner`
    /// only uses that reason once a face cluster recurs often enough to
    /// count as "known" (`knownPersonMinPhotos`), so a real person met
    /// only a few times in the library has a detected face but reason
    /// `.keep` — this was a real bug (reported as "Extras showing photos
    /// with people in them") until this check was added here too, as a
    /// second independent guard matching `LibraryScanner.filterExtras`'s.
    func deleteTripExtras(_ records: [PhotoRecord], cache: AnalysisCache?,
                          progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        guard !records.isEmpty else { return }

        let allowedReasons: Set<TierReason> = [.keep, .lowConfidence, .specialLandscape]
        let disallowedCount = records.filter { !allowedReasons.contains($0.reason) || $0.hasPeople }.count
        guard disallowedCount == 0 else {
            log.error("Refused to delete \(disallowedCount) protected or people-containing photo(s) via the trip-extras path")
            throw DeletionError.attemptedProtectedDeletion(count: disallowedCount)
        }

        var byReason: [TierReason: [PhotoRecord]] = [:]
        for record in records { byReason[record.reason, default: []].append(record) }
        for (reason, group) in byReason {
            try? cache?.logDeletion(ids: group.map(\.id), tier: .tier3Protected, reason: reason)
        }

        let ids = records.map(\.id)
        var deletedSoFar = 0

        for batch in ids.chunked(into: batchSize) {
            try Task.checkCancellation()
            try await deleteBatch(batch)
            deletedSoFar += batch.count
            progress?(deletedSoFar, ids.count)
        }

        try? cache?.removePhotoRows(ids: ids)
        log.notice("Deleted \(ids.count) trip-extra photo(s) across \(byReason.count) reason group(s)")
    }

    /// Deletes a Smart Delete rule match — a query can span every tier
    /// (unlike the trip-scoped Extras bucket), so the safety floor here is
    /// the union of what both other delete paths already allow: any
    /// Tier 1/2 photo (ordinary junk/redundant deletion, unchanged), plus
    /// a Tier 3 photo only when its reason is `.keep`/`.lowConfidence`/
    /// `.specialLandscape` AND it has no detected face or body — the same
    /// "kept by default, not for cause" carve-out `deleteTripExtras` uses,
    /// reused rather than re-invented so the two paths can't drift apart
    /// on what counts as "a real reason to protect this."
    ///
    /// Independently re-checked here regardless of what `SmartDeleteQuery`
    /// already filtered out, for the same reason every other guard in this
    /// file is independent: a bug in the query/UI layer must not be able
    /// to delete a real keeper.
    func deleteSmartSelection(_ records: [PhotoRecord], cache: AnalysisCache?,
                              progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        guard !records.isEmpty else { return }

        let allowedTier3Reasons: Set<TierReason> = [.keep, .lowConfidence, .specialLandscape]
        let disallowedCount = records.filter { record in
            if record.tier != .tier3Protected { return false }   // Tier 1/2: always allowed
            return !allowedTier3Reasons.contains(record.reason) || record.hasPeople
        }.count
        guard disallowedCount == 0 else {
            log.error("Refused to delete \(disallowedCount) protected photo(s) via Smart Delete")
            throw DeletionError.attemptedProtectedDeletion(count: disallowedCount)
        }

        var byReason: [TierReason: [PhotoRecord]] = [:]
        for record in records { byReason[record.reason, default: []].append(record) }
        for (reason, group) in byReason {
            guard let tier = group.first?.tier else { continue }
            try? cache?.logDeletion(ids: group.map(\.id), tier: tier, reason: reason)
        }

        let ids = records.map(\.id)
        var deletedSoFar = 0

        for batch in ids.chunked(into: batchSize) {
            try Task.checkCancellation()
            try await deleteBatch(batch)
            deletedSoFar += batch.count
            progress?(deletedSoFar, ids.count)
        }

        try? cache?.removePhotoRows(ids: ids)
        log.notice("Deleted \(ids.count) photo(s) via Smart Delete across \(byReason.count) reason group(s)")
    }

    private func deleteBatch(_ identifiers: [String]) async throws {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard fetchResult.count > 0 else { return }

        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch is CancellationError {
            throw DeletionError.cancelled
        } catch {
            throw DeletionError.photoKitFailed(error)
        }
    }
}
