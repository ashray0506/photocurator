import Foundation

/// One condition in a Smart Delete rule set — "add more rules" was asked
/// for directly, so this is a case-per-rule enum rather than a few fixed
/// booleans: a new rule is a new case plus one line in `matches(_:)`,
/// without touching the screen that builds/combines them.
///
/// A rule set is several `SmartDeleteRule`s ANDed together (`SmartDeleteQuery`
/// below) — "no face AND not in my selected people" reads naturally as two
/// rules stacked, matching how the feature was actually requested ("no
/// face, or face outside the selected, or delete selected").
enum SmartDeleteRule: Identifiable, Hashable {
    case noFace
    case faceNotIn(personIds: Set<String>)
    case inTier(Tier)
    case olderThan(days: Int)
    case screenshots
    case video   // reserved: PhotoRecord doesn't distinguish video today; see `matches`

    var id: String {
        switch self {
        case .noFace: return "noFace"
        case .faceNotIn(let ids): return "faceNotIn-\(ids.sorted().joined(separator: ","))"
        case .inTier(let tier): return "inTier-\(tier.rawValue)"
        case .olderThan(let days): return "olderThan-\(days)"
        case .screenshots: return "screenshots"
        case .video: return "video"
        }
    }

    var displayName: String {
        switch self {
        case .noFace: return "No face in photo"
        case .faceNotIn: return "Face not in selected people"
        case .inTier(let tier): return "In \(tier.shortName)"
        case .olderThan(let days): return "Older than \(days) days"
        case .screenshots: return "Screenshots"
        case .video: return "Videos"
        }
    }

    /// `personIdByClusterId` is the live scan's cluster->person mapping
    /// (`LibraryScanner.personIdByClusterId`), since a `PhotoRecord` only
    /// stores `faceClusterIds`, not `Person.id`s directly.
    func matches(_ record: PhotoRecord, personIdByClusterId: [Int: String], now: Date) -> Bool {
        switch self {
        case .noFace:
            return !record.hasPeople
        case .faceNotIn(let personIds):
            guard record.hasPeople else { return false }   // "a face that isn't X" implies there IS a face
            let recordPersonIds = Set(record.faceClusterIds.compactMap { personIdByClusterId[$0] })
            return !recordPersonIds.isEmpty && recordPersonIds.isDisjoint(with: personIds)
        case .inTier(let tier):
            return record.tier == tier
        case .olderThan(let days):
            guard let created = record.creationDate else { return false }
            return now.timeIntervalSince(created) > Double(days) * 86400
        case .screenshots:
            return record.media.isScreenshot
        case .video:
            return false   // PhotoRecord has no media-type field for video yet; reserved case, never matches today
        }
    }
}

/// Several rules ANDed together, plus the deliberate safety floor every
/// Smart Delete match still has to clear: never a photo with a real
/// protection reason (favorite, album, edited, known person), mirroring
/// `PhotoDeletionService.deleteTripExtras`'s guard. Smart Delete can reach
/// across every tier (unlike the trip-scoped Extras bucket), so this floor
/// matters even more here.
struct SmartDeleteQuery {
    var rules: [SmartDeleteRule] = []

    func matchingPhotos(in records: [PhotoRecord], personIdByClusterId: [Int: String],
                        now: Date = Date()) -> [PhotoRecord] {
        guard !rules.isEmpty else { return [] }
        return records.filter { record in
            guard Self.isSafeToConsider(record) else { return false }
            return rules.allSatisfy { $0.matches(record, personIdByClusterId: personIdByClusterId, now: now) }
        }
    }

    /// The preview-time safety floor, matching what
    /// `PhotoDeletionService.deleteSmartSelection` will actually accept at
    /// delete time: any Tier 1/2 photo, or a Tier 3 photo only when it's
    /// protected by default (`.keep`/`.lowConfidence`/`.specialLandscape`)
    /// and has no detected face or body. Kept in sync deliberately rather
    /// than shared code, since the delete-time check is the one that must
    /// never trust this one blindly — see that method's own doc comment.
    static func isSafeToConsider(_ record: PhotoRecord) -> Bool {
        guard record.tier == .tier3Protected else { return true }
        let allowedTier3Reasons: Set<TierReason> = [.keep, .lowConfidence, .specialLandscape]
        return allowedTier3Reasons.contains(record.reason) && !record.hasPeople
    }
}
