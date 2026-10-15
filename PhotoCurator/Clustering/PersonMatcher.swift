import Foundation
import CoreGraphics
import Vision

/// Carries `Person` identity forward across rescans. `FaceClusterer` has no
/// memory of its own — it reclusters from scratch every scan, starting
/// integer ids back at 0 — so without this, "the same person" would be a
/// different cluster id (and have no name, no history) every single time
/// the library is rescanned.
///
/// Matching strategy: a cluster's representative print is compared against
/// *every* print each saved `Person` has accumulated (not one frozen
/// anchor — see `Person.representativeFeaturePrints`' doc comment for why
/// that was the reported cause of a real person "splitting into many"),
/// taking the minimum distance across that person's prints. All
/// (cluster, person) pairs within threshold are then assigned globally by
/// ascending distance — the closest pair wins first, then the next closest
/// among what's left — rather than the earlier per-cluster "first match
/// wins" order, which let an arbitrary iteration order hand a person to a
/// worse-matching cluster and strand a better-matching one as a spurious
/// new person. This is a second, independent matching pass — not a change
/// to `FaceClusterer` itself, which stays exactly as tested; only known
/// clusters participate, since an unknown/one-off face isn't worth
/// tracking identity for across sessions.
struct PersonMatcher: Sendable {

    /// How many representative prints a `Person` accumulates before older
    /// ones are dropped (oldest first) — enough to average out a few bad
    /// angles/lighting conditions without the array growing unbounded for
    /// someone photographed in thousands of photos across many rescans.
    static let maxStoredPrints = 8

    struct Match {
        var clusterId: Int
        var person: Person
        /// True when this call created a new `Person` rather than
        /// matching an existing one — callers persist either way, but a
        /// UI can use this to, say, silently skip showing a "new person
        /// found" toast for ones already known.
        var isNewPerson: Bool
    }

    /// `clusterPrints` is one representative feature print per *known*
    /// `FaceCluster` id (callers build this from whichever face in the
    /// cluster had the largest area — the clearest shot). `photoCount`/
    /// `dayCount` come straight from the matching `FaceCluster`.
    func match(clusterPrints: [Int: Data],
              clusterStats: [Int: (photoCount: Int, dayCount: Int)],
              thumbnailPhotoId: [Int: String],
              thumbnailFaceBox: [Int: CGRect?] = [:],
              existingPeople: [Person],
              settings: CuratorSettings,
              now: Date = Date()) -> [Match] {
        struct Candidate { var clusterId: Int; var personIndex: Int; var distance: Float }

        // Every (cluster, person) pair within threshold, not just each
        // cluster's single best — the global assignment below needs the
        // full candidate set to resolve contention correctly.
        var candidates: [Candidate] = []
        for (clusterId, print) in clusterPrints {
            for (personIndex, person) in existingPeople.enumerated() {
                let distance = person.representativeFeaturePrints
                    .compactMap { FeaturePrintStore.distance(print, $0) }
                    .min()
                guard let distance, distance <= settings.faceMatchThreshold else { continue }
                candidates.append(Candidate(clusterId: clusterId, personIndex: personIndex, distance: distance))
            }
        }
        candidates.sort { $0.distance < $1.distance }

        var matchedPersonForCluster: [Int: Int] = [:]   // clusterId -> personIndex
        var claimedPersonIndices = Set<Int>()
        for candidate in candidates {
            guard matchedPersonForCluster[candidate.clusterId] == nil,
                  !claimedPersonIndices.contains(candidate.personIndex) else { continue }
            matchedPersonForCluster[candidate.clusterId] = candidate.personIndex
            claimedPersonIndices.insert(candidate.personIndex)
        }

        var matches: [Match] = []
        for (clusterId, print) in clusterPrints.sorted(by: { $0.key < $1.key }) {
            let stats = clusterStats[clusterId] ?? (0, 0)

            if let personIndex = matchedPersonForCluster[clusterId] {
                var person = existingPeople[personIndex]
                person.photoCount = stats.photoCount
                person.dayCount = stats.dayCount
                person.lastSeen = now
                if person.thumbnailPhotoId == nil {
                    person.thumbnailPhotoId = thumbnailPhotoId[clusterId]
                    person.thumbnailFaceBox = thumbnailFaceBox[clusterId] ?? nil
                }
                person.representativeFeaturePrints.append(print)
                if person.representativeFeaturePrints.count > Self.maxStoredPrints {
                    person.representativeFeaturePrints.removeFirst(
                        person.representativeFeaturePrints.count - Self.maxStoredPrints)
                }
                matches.append(Match(clusterId: clusterId, person: person, isNewPerson: false))
            } else {
                let person = Person(representativeFeaturePrints: [print],
                                    thumbnailPhotoId: thumbnailPhotoId[clusterId],
                                    thumbnailFaceBox: thumbnailFaceBox[clusterId] ?? nil,
                                    photoCount: stats.photoCount,
                                    dayCount: stats.dayCount,
                                    firstSeen: now,
                                    lastSeen: now)
                matches.append(Match(clusterId: clusterId, person: person, isNewPerson: true))
            }
        }

        return matches
    }
}
