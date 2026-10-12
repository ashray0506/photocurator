import Foundation
import os

/// Assigns every photo exactly one tier (PRD §6).
///
/// Order matters and is load-bearing for safety: **Tier 3 is evaluated first
/// and always wins**. A photo that qualifies for protection can never fall
/// through to Tier 1 or Tier 2 regardless of how junky its other signals look.
/// `PhotoCuratorTests` asserts this directly against PRD §13.
struct TierAssigner: Sendable {

    struct Context {
        /// Known-person clusters, from `FaceClusterer`.
        var knownClusterIds: Set<Int>
        /// photoId -> cluster id of the largest face in frame.
        var largestFaceCluster: [String: Int]
        /// Aesthetics score at the "special landscape" percentile.
        var specialLandscapeThreshold: Double
        /// Photos the user already locked with "Keep all" (PRD §6, Tier 3).
        var confirmedKeepIds: Set<String>
        /// photoId -> similarity cluster id.
        var clusterAssignments: [String: Int]
        /// Cluster id -> ids kept as the best of that cluster.
        var keptPerCluster: [Int: Set<String>]
        /// Clusters whose members are effectively identical frames.
        var exactDuplicateClusters: Set<Int>
    }

    private let log = Logger(subsystem: "app.photocurator", category: "tiers")

    func assign(_ records: [PhotoRecord],
                context: Context,
                settings: CuratorSettings) -> [PhotoRecord] {
        records.map { assign($0, context: context, settings: settings) }
    }

    func assign(_ record: PhotoRecord,
                context: Context,
                settings: CuratorSettings) -> PhotoRecord {
        var result = record

        // ------------------------------------------------------------------
        // Tier 3: protected. Checked first, always wins (PRD §6).
        // ------------------------------------------------------------------
        if let reason = protectedReason(record, context: context, settings: settings) {
            result.tier = .tier3Protected
            result.reason = reason
            return result
        }

        // ------------------------------------------------------------------
        // Tier 1: high-confidence junk (PRD §6).
        //
        // Evaluated before the uncertainty guard below, because Tier 1's
        // strongest signals (screenshot subtype, burst membership) come from
        // PhotoKit metadata and are certain without any pixel analysis.
        // ------------------------------------------------------------------
        if let reason = tier1Reason(record, context: context, settings: settings) {
            result.tier = .tier1
            result.reason = reason
            return result
        }

        // A photo whose pixels could not be analysed at all is maximum
        // uncertainty. Metadata-certain junk is already handled above, so
        // anything still here is protected rather than risked (PRD §9.2).
        if record.quality.isUnmeasured {
            result.tier = .tier3Protected
            result.reason = .lowConfidence
            return result
        }

        // ------------------------------------------------------------------
        // Tier 2: likely unwanted (PRD §6).
        // ------------------------------------------------------------------
        if let reason = tier2Reason(record, context: context, settings: settings) {
            result.tier = .tier2
            result.reason = reason
            return result
        }

        // Survivor: not junk, not a duplicate, not protected by a rule.
        // These are the photos the book is built from (PRD §10).
        result.tier = .tier3Protected
        result.reason = .keep
        return result
    }

    // MARK: Tier 3

    private func protectedReason(_ record: PhotoRecord,
                                 context: Context,
                                 settings: CuratorSettings) -> TierReason? {
        // The user rescued or locked this photo: nothing may re-tier it.
        if record.userOverride || context.confirmedKeepIds.contains(record.id) {
            return .favorite
        }
        if record.isFavorite { return .favorite }
        if record.inUserAlbum { return .inUserAlbum }
        if record.isEdited { return .edited }

        // Any known person in frame protects the photo (PRD §6).
        if record.faceClusterIds.contains(where: { context.knownClusterIds.contains($0) }) {
            return .knownPerson
        }

        // High-scoring no-face landscape (PRD §6).
        if !record.hasPeople, let aesthetics = record.quality.aesthetics,
           aesthetics >= context.specialLandscapeThreshold {
            return .specialLandscape
        }

        return nil
    }

    // MARK: Tier 1

    private func tier1Reason(_ record: PhotoRecord,
                             context: Context,
                             settings: CuratorSettings) -> TierReason? {
        // Screenshots: PhotoKit's own subtype is authoritative, so it needs no
        // confidence check. Receipts and documents come from Vision and do.
        if record.media.isScreenshot { return .screenshot }
        if let junk = record.junkType, record.junkConfidence >= settings.junkConfidenceMin {
            switch junk {
            case .screenshot: return .screenshot
            case .receipt, .document, .whiteboard, .meme: return .receiptOrDocument
            }
        }

        // Accidental shots: near-uniform frames (lens covered, pocket).
        // Each check is false when the signal was never measured, so a photo
        // we could not decode is never called junk (PRD §9.2).
        if record.quality.isAccidental(above: settings.accidentalUniformityMin) {
            return .accidentalShot
        }

        // Extremes only. "Extremely dark" and "extremely blurry" are separate
        // from Tier 2's mild cases, so the floors here are deliberately harsh.
        if record.quality.isDark(below: settings.darkBrightnessMax) { return .extremelyDark }
        if record.quality.isBlurry(below: settings.blurrySharpnessMax) { return .extremelyBlurry }

        // Exact duplicates and burst leftovers, where a best frame was kept.
        if let clusterId = context.clusterAssignments[record.id],
           let kept = context.keptPerCluster[clusterId],
           !kept.contains(record.id) {
            if context.exactDuplicateClusters.contains(clusterId) { return .exactDuplicate }
            if record.media.isBurst { return .burstLeftover }
        }

        return nil
    }

    // MARK: Tier 2

    private func tier2Reason(_ record: PhotoRecord,
                             context: Context,
                             settings: CuratorSettings) -> TierReason? {
        // Near-duplicates beyond the per-cluster cap, best photos kept.
        if let clusterId = context.clusterAssignments[record.id],
           let kept = context.keptPerCluster[clusterId],
           !kept.contains(record.id) {
            return .nearDuplicate
        }

        // Low-scoring no-face landscape. Requires a measured score: an
        // unscored landscape is not evidence of a bad one.
        if !record.hasPeople, let aesthetics = record.quality.aesthetics,
           aesthetics <= settings.lowAestheticLandscapeMax {
            return .lowAestheticLandscape
        }

        // Stranger-focused: the largest face in frame belongs to an unfamiliar
        // person (PRD §5.4, §6). A photo with no identified largest face is
        // never called stranger-focused.
        if let largest = context.largestFaceCluster[record.id],
           !context.knownClusterIds.contains(largest) {
            return .strangerFocused
        }

        return nil
    }

    // MARK: Threshold helper

    /// The aesthetics score at the "special landscape" percentile, computed
    /// over the library's no-face photos (PRD §6: default top 15%).
    static func specialLandscapeThreshold(for records: [PhotoRecord],
                                          settings: CuratorSettings) -> Double {
        let scores = records
            .filter { !$0.hasPeople }
            .compactMap(\.quality.aesthetics)
            .sorted()
        guard !scores.isEmpty else { return 1.0 }
        let index = Int(Double(scores.count - 1) * settings.specialLandscapePercentile)
        return scores[max(0, min(scores.count - 1, index))]
    }
}
