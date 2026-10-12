import Foundation
import CoreLocation
import Vision
import os

/// Groups near-identical photos (PRD §7).
///
/// Time and GPS are the primary signals, scene similarity confirms, and outfit
/// is a tiebreaker that may only **split** a cluster. The PRD is explicit that
/// outfit must never be the sole reason a photo is deleted, so it is applied as
/// a post-pass that divides an existing cluster rather than as a term in the
/// similarity score.
struct SimilarityClusterer: Sendable {

    struct Output {
        var clusters: [PhotoCluster]
        /// photoId -> cluster id
        var assignments: [String: Int]
        /// M1 report input: how many extra clusters outfit splitting created,
        /// keyed by day (PRD §12, M1).
        var outfitSplitsByDay: [Date: Int]
    }

    private let log = Logger(subsystem: "app.photocurator", category: "clustering")

    /// Candidates must be sorted by capture date.
    func cluster(_ records: [PhotoRecord], settings: CuratorSettings) -> Output {
        // Decode each feature print once: the inner loop compares many pairs.
        var prints: [String: VNFeaturePrintObservation] = [:]
        for record in records {
            if let observation = FeaturePrintStore.decode(record.featurePrint) {
                prints[record.id] = observation
            }
        }

        let sorted = records.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }

        // Pass 1: sequential grouping on time, place and scene.
        var groups: [[PhotoRecord]] = []
        var current: [PhotoRecord] = []

        for record in sorted {
            guard let last = current.last else {
                current = [record]
                continue
            }
            if belongTogether(last, record, prints: prints, settings: settings) {
                current.append(record)
            } else {
                groups.append(current)
                current = [record]
            }
        }
        if !current.isEmpty { groups.append(current) }

        // Pass 2: outfit splitting (PRD §7: "same day, same place, different
        // outfit" is a different part of the day, so keep at least one of each).
        var clusters: [PhotoCluster] = []
        var assignments: [String: Int] = [:]
        var outfitSplitsByDay: [Date: Int] = [:]
        var nextId = 0

        for group in groups {
            let subgroups = splitByOutfit(group, settings: settings)
            if subgroups.count > 1, let day = group.first?.dayStart() {
                outfitSplitsByDay[day, default: 0] += subgroups.count - 1
            }
            for (index, subgroup) in subgroups.enumerated() {
                var cluster = PhotoCluster(id: nextId)
                cluster.date = subgroup.first?.creationDate
                cluster.photoIds = subgroup.map(\.id)
                cluster.createdByOutfitSplit = index > 0
                for record in subgroup { assignments[record.id] = nextId }
                clusters.append(cluster)
                nextId += 1
            }
        }

        let multi = clusters.filter { $0.photoIds.count > 1 }.count
        log.notice("Built \(clusters.count) clusters (\(multi) with more than one photo)")

        return Output(clusters: clusters,
                      assignments: assignments,
                      outfitSplitsByDay: outfitSplitsByDay)
    }

    // MARK: Similarity

    /// Combined similarity from the three non-outfit signals (PRD §7).
    /// All three must agree; any one failing separates the photos.
    private func belongTogether(_ a: PhotoRecord,
                                _ b: PhotoRecord,
                                prints: [String: VNFeaturePrintObservation],
                                settings: CuratorSettings) -> Bool {
        // Time gap (primary).
        guard let dateA = a.creationDate, let dateB = b.creationDate else { return false }
        let gap = abs(dateB.timeIntervalSince(dateA))
        guard gap <= settings.clusterMaxTimeGap else { return false }

        // Never span a day boundary: the book is built per day (PRD §10).
        guard a.dayStart() == b.dayStart() else { return false }

        // GPS distance (primary). When either photo lacks GPS we fall through
        // to scene similarity rather than assuming they are together.
        if let locationA = a.location, let locationB = b.location {
            guard locationA.distance(from: locationB) <= settings.clusterMaxDistance else {
                return false
            }
        }

        // Scene similarity (confirming). A missing print means we cannot
        // confirm, so the photos stay apart and nothing is marked duplicate.
        guard let printA = prints[a.id], let printB = prints[b.id],
              let distance = FeaturePrintStore.distance(printA, printB) else {
            return false
        }
        return distance <= settings.sceneSimilarityThreshold
    }

    /// Splits a group when the main subject's outfit changes (PRD §7).
    ///
    /// Only photos that actually have an outfit print participate; photos with
    /// no people keep scene/time/GPS behaviour and stay in the first subgroup.
    private func splitByOutfit(_ group: [PhotoRecord],
                               settings: CuratorSettings) -> [[PhotoRecord]] {
        guard group.count > 1 else { return [group] }

        // Group shots: compare the best-matching person, which we approximate
        // by the largest face's outfit (PRD §7).
        func primaryOutfit(_ record: PhotoRecord) -> OutfitPrint? {
            record.outfits.max { $0.faceArea < $1.faceArea }
        }

        let withOutfits = group.filter { primaryOutfit($0) != nil }
        guard withOutfits.count > 1 else { return [group] }

        var subgroups: [[PhotoRecord]] = []
        var exemplars: [OutfitPrint] = []

        for record in group {
            guard let outfit = primaryOutfit(record) else {
                // No people: leave it with the first subgroup.
                if subgroups.isEmpty { subgroups.append([]) ; exemplars.append(outfitPlaceholder()) }
                subgroups[0].append(record)
                continue
            }

            var matched: Int?
            for (index, exemplar) in exemplars.enumerated() {
                if outfitDistance(exemplar, outfit) <= settings.outfitSplitThreshold {
                    matched = index
                    break
                }
            }

            if let matched {
                subgroups[matched].append(record)
            } else {
                exemplars.append(outfit)
                subgroups.append([record])
            }
        }

        return subgroups.filter { !$0.isEmpty }
    }

    /// Colour histogram distance, refined by torso feature print when both
    /// are present.
    private func outfitDistance(_ a: OutfitPrint, _ b: OutfitPrint) -> Double {
        let colorDistance = ImageQualityAnalyzer.histogramDistance(a.histogram, b.histogram)
        guard let printDistance = FeaturePrintStore.distance(a.featurePrint, b.featurePrint) else {
            return colorDistance
        }
        // Colour dominates: it survives pose and crop changes far better than
        // a feature print of a small torso crop.
        return 0.7 * colorDistance + 0.3 * min(1.0, Double(printDistance))
    }

    private func outfitPlaceholder() -> OutfitPrint {
        OutfitPrint(histogram: [], featurePrint: nil, faceArea: 0)
    }
}
