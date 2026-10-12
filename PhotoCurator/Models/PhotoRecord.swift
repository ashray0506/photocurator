import Foundation
import CoreLocation

/// Why a photo landed in its tier. Stored so the M1 report and the later
/// review screens can break counts down by reason without re-analysing.
enum TierReason: String, Codable, CaseIterable, Sendable {
    // Tier 3 (protected)
    case favorite
    case inUserAlbum
    case edited
    case knownPerson
    case specialLandscape
    case lowConfidence        // PRD §9.2: unsure means keep

    // Tier 1 (high-confidence junk)
    case exactDuplicate
    case burstLeftover
    case screenshot
    case receiptOrDocument
    case extremelyDark
    case extremelyBlurry
    case accidentalShot       // pocket photo / lens covered

    // Tier 2 (likely unwanted)
    case nearDuplicate
    case lowAestheticLandscape
    case strangerFocused

    // Default
    case keep

    var displayName: String {
        switch self {
        case .favorite: return "Favorite"
        case .inUserAlbum: return "In user album"
        case .edited: return "Edited"
        case .knownPerson: return "Known person"
        case .specialLandscape: return "Special landscape"
        case .lowConfidence: return "Low confidence (kept)"
        case .exactDuplicate: return "Exact duplicate"
        case .burstLeftover: return "Burst leftover"
        case .screenshot: return "Screenshot"
        case .receiptOrDocument: return "Receipt or document"
        case .extremelyDark: return "Extremely dark"
        case .extremelyBlurry: return "Blurry"
        case .accidentalShot: return "Accidental shot"
        case .nearDuplicate: return "Near duplicate"
        case .lowAestheticLandscape: return "Low-scoring landscape"
        case .strangerFocused: return "Stranger-focused"
        case .keep: return "Keep"
        }
    }
}

enum Tier: Int, Codable, Comparable, Sendable {
    case tier1 = 1          // high-confidence junk
    case tier2 = 2          // likely unwanted
    case tier3Protected = 3 // never touched

    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    var displayName: String {
        switch self {
        case .tier1: return "Tier 1 · High confidence junk"
        case .tier2: return "Tier 2 · Likely unwanted"
        case .tier3Protected: return "Tier 3 · Protected"
        }
    }
}

enum JunkType: String, Codable, Sendable {
    case screenshot, receipt, document, whiteboard, meme
}

/// Media subtypes we care about from PhotoKit (PRD §5.1).
struct MediaFlags: Codable, Sendable {
    var isScreenshot = false
    var isBurst = false
    var isLivePhoto = false
    var isPanorama = false
    var isHDR = false
}

/// Per-photo quality signals (PRD §5.2).
///
/// The pixel signals are **optional on purpose**: nil means "we could not
/// measure this", which is different from "we measured it and it was zero".
/// A photo whose pixels could not be decoded would otherwise look maximally
/// dark, blurry and flat, and be deleted as junk — the exact opposite of
/// PRD §9.2 ("when confidence is below the threshold, keep"). Tier rules must
/// therefore treat a nil signal as "no evidence", never as evidence of junk.
struct QualitySignals: Codable, Sendable {
    /// Laplacian variance, normalised 0...1. Higher is sharper. Nil if unmeasured.
    var sharpness: Double?
    /// Mean luma 0...1. Nil if unmeasured.
    var brightness: Double?
    /// Fraction of pixels clipped at either end. Nil if unmeasured.
    var clippedFraction: Double?
    /// Vision aesthetics score, normalised 0...1 (macOS 15+). Nil if unmeasured.
    var aesthetics: Double?
    /// Near-uniform image: lens covered or pocket shot. Nil if unmeasured.
    var uniformity: Double?
    /// Best face capture quality in frame, 0...1, nil when no faces.
    var bestFaceQuality: Double?

    /// True only when the signal was measured and is below the floor, so an
    /// unmeasured photo is never reported as junk.
    func isDark(below floor: Double) -> Bool {
        guard let brightness else { return false }
        return brightness <= floor
    }

    func isBlurry(below floor: Double) -> Bool {
        guard let sharpness else { return false }
        return sharpness <= floor
    }

    func isAccidental(above floor: Double) -> Bool {
        guard let uniformity else { return false }
        return uniformity >= floor
    }

    /// Neutral stand-ins for *ranking* only (PRD §7 best-photo scoring), where
    /// an unmeasured photo should sit mid-pack rather than win or lose outright.
    var aestheticsForRanking: Double { aesthetics ?? 0.5 }
    var sharpnessForRanking: Double { sharpness ?? 0.5 }
    var brightnessForRanking: Double { brightness ?? 0.45 }
    var clippedForRanking: Double { clippedFraction ?? 0 }

    /// True when no pixel-level signal could be measured at all.
    var isUnmeasured: Bool {
        sharpness == nil && brightness == nil && uniformity == nil
    }
}

/// A detected person's outfit fingerprint (PRD §5.6).
/// Used only to split clusters, never to delete on its own.
struct OutfitPrint: Codable, Sendable {
    /// Coarse torso colour histogram.
    var histogram: [Float]
    /// Vision feature print of the torso crop.
    var featurePrint: Data?
    /// Normalised area of the owning face in frame, used to pick the subject.
    var faceArea: Double
}

/// The central record. One per PHAsset. Cached keyed by
/// `localIdentifier` + `modificationDate` (PRD §5).
struct PhotoRecord: Codable, Identifiable, Sendable {
    // Identity
    var id: String                   // PHAsset.localIdentifier
    var modificationDate: Date?      // cache invalidation key

    // Metadata (PRD §5.1)
    var creationDate: Date?
    var latitude: Double?
    var longitude: Double?
    var isFavorite = false
    var isEdited = false
    var inUserAlbum = false
    var media = MediaFlags()
    var pixelWidth = 0
    var pixelHeight = 0
    var byteSize: Int64 = 0

    // Analysis
    var quality = QualitySignals()
    var junkType: JunkType?
    var junkConfidence: Double = 0
    var featurePrint: Data?
    var faceCount = 0
    var bodyCount = 0
    var faceClusterIds: [Int] = []
    var largestFaceClusterId: Int?
    var largestFaceArea: Double = 0
    var outfits: [OutfitPrint] = []
    /// Per-face feature prints, kept so a cached photo can be re-clustered
    /// library-wide without re-running Vision over its pixels.
    var pendingFacePrints: [PendingFace] = []

    // Assignment
    var tier: Tier = .tier3Protected
    var reason: TierReason = .keep
    var clusterId: Int?
    var userOverride: Bool = false   // rescued by the user
    var tasteScore: Double?          // M6, unused in M1

    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    var hasPeople: Bool { faceCount > 0 || bodyCount > 0 }

    /// Day bucket in the user's current calendar, used for grouping (PRD §10.2).
    func dayStart(calendar: Calendar = .current) -> Date? {
        creationDate.map { calendar.startOfDay(for: $0) }
    }
}

/// A library-wide face cluster (PRD §11).
struct FaceCluster: Codable, Identifiable, Sendable {
    var id: Int
    var photoCount: Int = 0
    var dayCount: Int = 0
    /// PRD §5.4: known if it appears in >= N photos or spans >= 3 days.
    var isKnown: Bool = false
}

/// A similarity cluster of near-identical photos (PRD §11).
struct PhotoCluster: Codable, Identifiable, Sendable {
    var id: Int
    var date: Date?
    var placeName: String?
    var photoIds: [String] = []
    var keptIds: [String] = []
    /// True when this cluster was split off from another by outfit difference.
    /// Tracked so M1 can report how many extra clusters outfit splitting creates.
    var createdByOutfitSplit: Bool = false
}
