import Foundation

/// Every tunable threshold in one place (PRD §9.6: adjustable with sensible
/// defaults and a reset). The PRD's open questions in §14 are all values here,
/// so M1's report is what we use to tune them.
struct CuratorSettings: Codable, Equatable, Sendable {

    // MARK: Known person (PRD §5.4)

    /// A face cluster is known if it appears in at least this many photos...
    var knownPersonMinPhotos = 15
    /// ...or spans at least this many distinct days.
    var knownPersonMinDays = 3
    /// Feature-print distance below which two faces are the same person.
    var faceMatchThreshold: Float = 0.62

    // MARK: Special landscape (PRD §6, Tier 3)

    /// No-face landscapes in the top fraction of the library by aesthetics
    /// are protected as "special". Default top 15%.
    var specialLandscapePercentile = 0.85
    /// Tier 2 catches no-face landscapes below this aesthetics score.
    var lowAestheticLandscapeMax = 0.35

    // MARK: Quality floors (PRD §5.2)

    var darkBrightnessMax = 0.06
    var blurrySharpnessMax = 0.04
    var accidentalUniformityMin = 0.97
    var clippedFractionMax = 0.55

    // MARK: Junk classification (PRD §5.3)

    /// Below this confidence we do not classify as junk; the photo is kept
    /// (PRD §9.2: when unsure, keep).
    var junkConfidenceMin = 0.80

    // MARK: Place segmentation and trips (PRD §10.2)

    /// Within a day, photos more than this far apart in time start a new
    /// place segment. Separate from `clusterMaxTimeGap` (PRD §7): that one
    /// decides whether two photos are near-duplicates, this one decides
    /// whether they belong to the same stop on a trip.
    var placeSegmentMaxTimeGap: TimeInterval = 30 * 60
    /// Within a day, photos more than this far apart (metres) start a new
    /// place segment.
    var placeSegmentMaxDistance: CLLocationDistanceValue = 500
    /// A trip boundary forms when consecutive active days jump at least this
    /// far (metres), even with no date gap -- catches a same-week trip to
    /// another city (PRD §10, adapted for GPS-rich libraries).
    var tripPlaceJumpDistance: CLLocationDistanceValue = 50_000

    // MARK: Clustering (PRD §7)

    /// Primary signal: photos more than this far apart in time never cluster.
    var clusterMaxTimeGap: TimeInterval = 30 * 60
    /// Primary signal: metres.
    var clusterMaxDistance: CLLocationDistanceValue = 500
    /// Scene feature-print distance below which two photos are the same scene.
    var sceneSimilarityThreshold: Float = 0.35
    /// Exact-duplicate threshold: effectively identical frames.
    var exactDuplicateThreshold: Float = 0.08
    /// Outfit histogram distance above which we split a cluster.
    var outfitSplitThreshold: Double = 0.45
    /// Max photos kept per cluster (PRD §7: default 3, range 1...5).
    var perClusterCap = 3

    // MARK: Best-photo weights (PRD §7, §8)

    var weightAesthetics = 0.40
    var weightSharpness = 0.20
    var weightExposure = 0.15
    var weightFaceQuality = 0.15
    var weightKnownPersonBoost = 0.10
    /// PRD §8: final = 0.6 * quality + 0.4 * tasteScore when taste is enabled.
    var tasteBlendWeight = 0.40
    var tasteModelEnabled = false    // M6; off in M1

    // MARK: Pipeline

    /// Concurrent Vision requests. Tuned at runtime to core count.
    var maxConcurrentAnalyses = 6
    /// Pixel width of the thumbnail used for analysis.
    var analysisThumbnailSize = 512

    static let `default` = CuratorSettings()

    mutating func resetToDefaults() { self = .default }
}

/// Small alias so the settings file does not need to import CoreLocation.
typealias CLLocationDistanceValue = Double
