import Foundation
import Vision
import os

/// Library-wide face clustering (PRD §5.4).
///
/// A cluster is **known** when it appears in at least `knownPersonMinPhotos`
/// photos or spans at least `knownPersonMinDays` distinct days. Known people
/// protect their photos into Tier 3, so this runs before tier assignment.
///
/// Greedy single-link clustering against cluster exemplars: at 10k photos the
/// all-pairs alternative is ~50M distance computations, while exemplar matching
/// stays linear in photos times clusters.
struct FaceClusterer: Sendable {

    /// One face awaiting assignment.
    struct Candidate {
        var photoId: String
        var day: Date?
        var area: Double
        var featurePrint: Data?
    }

    struct Output {
        var clusters: [FaceCluster]
        /// photoId -> cluster ids present in that photo
        var assignments: [String: [Int]]
        /// photoId -> cluster id of the *largest* face in that photo,
        /// which is what the stranger-focused rule in PRD §6 needs.
        var largestFaceCluster: [String: Int]
    }

    private let log = Logger(subsystem: "app.photocurator", category: "faces")

    func cluster(_ candidates: [Candidate], settings: CuratorSettings) -> Output {
        var exemplars: [(id: Int, print: VNFeaturePrintObservation)] = []
        var photoIds: [Int: Set<String>] = [:]
        var days: [Int: Set<Date>] = [:]
        var assignments: [String: [Int]] = [:]
        var bestFace: [String: (area: Double, cluster: Int)] = [:]
        var nextId = 0

        for candidate in candidates {
            guard let observation = FeaturePrintStore.decode(candidate.featurePrint) else {
                // No usable print: we cannot say who this is, so the face is
                // left unassigned. PRD §9.2 means that errs toward keeping,
                // because an unassigned face never marks a photo as a stranger.
                continue
            }

            var matchedId: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            for exemplar in exemplars {
                guard let distance = FeaturePrintStore.distance(exemplar.print, observation) else { continue }
                if distance < bestDistance {
                    bestDistance = distance
                    matchedId = exemplar.id
                }
            }

            let clusterId: Int
            if let matchedId, bestDistance <= settings.faceMatchThreshold {
                clusterId = matchedId
            } else {
                clusterId = nextId
                nextId += 1
                exemplars.append((clusterId, observation))
            }

            photoIds[clusterId, default: []].insert(candidate.photoId)
            if let day = candidate.day { days[clusterId, default: []].insert(day) }

            var existing = assignments[candidate.photoId] ?? []
            if !existing.contains(clusterId) {
                existing.append(clusterId)
                assignments[candidate.photoId] = existing
            }

            if let current = bestFace[candidate.photoId] {
                if candidate.area > current.area {
                    bestFace[candidate.photoId] = (candidate.area, clusterId)
                }
            } else {
                bestFace[candidate.photoId] = (candidate.area, clusterId)
            }
        }

        let clusters = (0..<nextId).map { id -> FaceCluster in
            let photoCount = photoIds[id]?.count ?? 0
            let dayCount = days[id]?.count ?? 0
            let isKnown = photoCount >= settings.knownPersonMinPhotos
                       || dayCount >= settings.knownPersonMinDays
            return FaceCluster(id: id, photoCount: photoCount, dayCount: dayCount, isKnown: isKnown)
        }

        let knownCount = clusters.filter(\.isKnown).count
        log.notice("Clustered \(candidates.count) faces into \(clusters.count) people, \(knownCount) known")

        return Output(clusters: clusters,
                      assignments: assignments,
                      largestFaceCluster: bestFace.mapValues(\.cluster))
    }
}
