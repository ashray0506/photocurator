import Foundation

/// Ranks photos within a cluster so the best survive (PRD §7).
///
/// `tasteScore` is blended in only when the taste model is enabled and trained
/// (M6). PRD §8 requires that disabling the model gives results identical to
/// generic scoring, so the blend is skipped entirely rather than folded in with
/// a neutral value.
struct BestPhotoScorer: Sendable {

    private let settings: CuratorSettings
    private let knownClusterIds: Set<Int>

    init(settings: CuratorSettings, knownClusterIds: Set<Int>) {
        self.settings = settings
        self.knownClusterIds = knownClusterIds
    }

    /// Technical and compositional quality, 0...1.
    func qualityScore(_ record: PhotoRecord) -> Double {
        let quality = record.quality

        // Exposure: a mid-range mean luma with little clipping scores best.
        // Ranking uses neutral stand-ins for unmeasured signals so an
        // unanalysed photo sits mid-pack instead of winning or losing outright.
        let exposurePenalty = abs(quality.brightnessForRanking - 0.45) / 0.45
        let exposureScore = max(0, 1 - exposurePenalty) * (1 - quality.clippedForRanking)

        var score = settings.weightAesthetics * quality.aestheticsForRanking
                  + settings.weightSharpness * quality.sharpnessForRanking
                  + settings.weightExposure * exposureScore

        // Eyes open and smiling, via face capture quality (PRD §7).
        if let faceQuality = quality.bestFaceQuality {
            score += settings.weightFaceQuality * faceQuality
        } else {
            // No face: redistribute that weight to aesthetics so landscapes
            // are not penalised for having nobody in them.
            score += settings.weightFaceQuality * quality.aestheticsForRanking
        }

        // Known people boost (PRD §7).
        if record.faceClusterIds.contains(where: { knownClusterIds.contains($0) }) {
            score += settings.weightKnownPersonBoost
        }

        return min(1, max(0, score))
    }

    /// Final ranking score, blending taste when it is available (PRD §8).
    func finalScore(_ record: PhotoRecord) -> Double {
        let quality = qualityScore(record)
        guard settings.tasteModelEnabled, let taste = record.tasteScore else {
            return quality
        }
        let tasteWeight = settings.tasteBlendWeight
        return (1 - tasteWeight) * quality + tasteWeight * taste
    }

    /// Picks the keepers for one cluster, honouring the per-cluster cap
    /// (PRD §7: default 3, configurable 1...5).
    func keepers(in cluster: [PhotoRecord]) -> Set<String> {
        guard !cluster.isEmpty else { return [] }
        let cap = max(1, min(5, settings.perClusterCap))

        // A cluster at or under the cap loses nothing.
        guard cluster.count > cap else { return Set(cluster.map(\.id)) }

        let ranked = cluster.sorted { finalScore($0) > finalScore($1) }
        return Set(ranked.prefix(cap).map(\.id))
    }
}
