import Foundation
import CoreGraphics

/// A named person, stable across rescans — unlike `FaceCluster`, whose
/// integer `id` is only valid within one scan session (clustering runs
/// fresh every time, starting its ids back at 0). A `Person` persists its
/// own UUID, a user-editable name, and a representative face feature
/// print; after each scan's clustering finishes, `PersonMatcher` matches
/// that session's cluster exemplars against saved `Person` records by
/// feature-print distance (the same metric `FaceClusterer` itself uses
/// internally) to carry identity forward, auto-creating a new `Person`
/// for a cluster that matches none well enough.
///
/// This groundwork is what the People section and Smart Delete's "face
/// not in my selection" rule both need — without it there would be no
/// stable thing to name, remember, or select across sessions at all.
struct Person: Codable, Identifiable, Sendable, Hashable {
    var id: String = UUID().uuidString
    /// User-assigned; nil until renamed, in which case the UI shows a
    /// generic placeholder ("Person seen 42 times") rather than an empty
    /// name — nil, not an empty string, so "was this ever named" stays
    /// unambiguous.
    var name: String?
    /// Representative face observations, archived the same way
    /// `FeaturePrintStore` already does for duplicate/person-cluster
    /// matching elsewhere — plural, not one frozen anchor: a single print
    /// from one photo (one angle, one lighting, one age) was a fragile
    /// match target and the reported cause of a real person "splitting
    /// into many" across rescans. Each rescan that confirms a match adds
    /// its own representative print (capped — see `PersonMatcher`), so
    /// matching compares a new cluster against every print this person
    /// has ever been seen with and keeps the closest, not just the first.
    var representativeFeaturePrints: [Data] = []

    /// Old single-print field, kept only so a `Person` saved before this
    /// change still decodes (`Codable`'s synthesized init treats a
    /// missing key as using a property's default — here that default is
    /// a computed migration, not a stored one, since storing both the old
    /// and new field permanently would never clean the old data up).
    private enum CodingKeys: String, CodingKey {
        case id, name, representativeFeaturePrints, thumbnailPhotoId, thumbnailFaceBox,
             photoCount, dayCount, firstSeen, lastSeen
        case legacyRepresentativeFeaturePrint = "representativeFeaturePrint"
    }

    init(id: String = UUID().uuidString, name: String? = nil,
        representativeFeaturePrints: [Data] = [], thumbnailPhotoId: String? = nil,
        thumbnailFaceBox: CGRect? = nil, photoCount: Int = 0, dayCount: Int = 0,
        firstSeen: Date? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.representativeFeaturePrints = representativeFeaturePrints
        self.thumbnailPhotoId = thumbnailPhotoId
        self.thumbnailFaceBox = thumbnailFaceBox
        self.photoCount = photoCount
        self.dayCount = dayCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name)
        var prints = try container.decodeIfPresent([Data].self, forKey: .representativeFeaturePrints) ?? []
        if prints.isEmpty, let legacy = try container.decodeIfPresent(Data.self, forKey: .legacyRepresentativeFeaturePrint) {
            prints = [legacy]
        }
        representativeFeaturePrints = prints
        thumbnailPhotoId = try container.decodeIfPresent(String.self, forKey: .thumbnailPhotoId)
        thumbnailFaceBox = try container.decodeIfPresent(CGRect.self, forKey: .thumbnailFaceBox)
        photoCount = try container.decodeIfPresent(Int.self, forKey: .photoCount) ?? 0
        dayCount = try container.decodeIfPresent(Int.self, forKey: .dayCount) ?? 0
        firstSeen = try container.decodeIfPresent(Date.self, forKey: .firstSeen)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(representativeFeaturePrints, forKey: .representativeFeaturePrints)
        try container.encodeIfPresent(thumbnailPhotoId, forKey: .thumbnailPhotoId)
        try container.encodeIfPresent(thumbnailFaceBox, forKey: .thumbnailFaceBox)
        try container.encode(photoCount, forKey: .photoCount)
        try container.encode(dayCount, forKey: .dayCount)
        try container.encodeIfPresent(firstSeen, forKey: .firstSeen)
        try container.encodeIfPresent(lastSeen, forKey: .lastSeen)
    }

    /// The photo this person's face crop thumbnail is extracted from —
    /// whichever photo had the largest face at the time this `Person`
    /// was created or last confirmed.
    var thumbnailPhotoId: String?
    /// That photo's face bounding box (Vision's normalised, bottom-left
    /// coordinate space), for cropping a tight face thumbnail rather than
    /// showing the whole photo. Nil falls back to the full photo.
    var thumbnailFaceBox: CGRect?
    var photoCount: Int = 0
    var dayCount: Int = 0
    var firstSeen: Date?
    var lastSeen: Date?

    var displayName: String {
        name ?? "Person seen \(photoCount.formatted()) time\(photoCount == 1 ? "" : "s")"
    }
}
