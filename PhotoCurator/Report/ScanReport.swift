import Foundation

/// The M1 deliverable (PRD §12, M1): a read-only report of counts per tier and
/// per reason, day grouping, and how many extra clusters outfit splitting
/// creates per day so its accuracy can be judged before M4 relies on it.
///
/// This is also the dry-run summary that PRD §4.4 and §9.1 require before any
/// deletion exists.
struct ScanReport {

    struct TierSummary: Identifiable {
        var id: Int { tier.rawValue }
        var tier: Tier
        var count: Int
        var byteSize: Int64
        /// Counts per reason, most common first.
        var reasons: [(reason: TierReason, count: Int)]

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
        }
    }

    struct DaySummary: Identifiable {
        var id: Date { day }
        var day: Date
        var photoCount: Int
        var clusterCount: Int
        /// Extra clusters created purely by outfit splitting (PRD §12, M1).
        var outfitSplitCount: Int
        var hasLocation: Bool
    }

    var totalPhotos: Int
    var tiers: [TierSummary]
    var days: [DaySummary]

    // People (PRD §5.4)
    var faceClusterCount: Int
    var knownPersonCount: Int
    var photosWithPeople: Int

    // Clustering (PRD §7)
    var clusterCount: Int
    var multiPhotoClusterCount: Int
    var largestClusterSize: Int
    var totalOutfitSplits: Int

    // Thresholds actually used, echoed so the report is self-describing while
    // the PRD §14 open questions are still being tuned.
    var specialLandscapeThreshold: Double

    // Performance, against the PRD §13 budgets.
    var duration: Duration
    var photosFromCache: Int

    var remainingAfterBothTiers: Int {
        tiers.first { $0.tier == .tier3Protected }?.count ?? 0
    }

    /// Overall GPS coverage across *every* day, not just the ones shown in
    /// a truncated list. A UI that only displays the first N of `days`
    /// (oldest-first) can make a library look GPS-less when really only
    /// its earliest, sparsest-metadata years lack location — this number
    /// stays accurate regardless of how the day list itself is truncated
    /// or sorted for display.
    var daysWithLocation: Int { days.count(where: \.hasLocation) }
    var daysTotal: Int { days.count }

    var formattedDuration: String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%.0fm %.0fs", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
    }

    static let empty = ScanReport(
        totalPhotos: 0, tiers: [], days: [],
        faceClusterCount: 0, knownPersonCount: 0, photosWithPeople: 0,
        clusterCount: 0, multiPhotoClusterCount: 0, largestClusterSize: 0,
        totalOutfitSplits: 0, specialLandscapeThreshold: 0,
        duration: .zero, photosFromCache: 0)

    // MARK: Build

    init(totalPhotos: Int, tiers: [TierSummary], days: [DaySummary],
         faceClusterCount: Int, knownPersonCount: Int, photosWithPeople: Int,
         clusterCount: Int, multiPhotoClusterCount: Int, largestClusterSize: Int,
         totalOutfitSplits: Int, specialLandscapeThreshold: Double,
         duration: Duration, photosFromCache: Int) {
        self.totalPhotos = totalPhotos
        self.tiers = tiers
        self.days = days
        self.faceClusterCount = faceClusterCount
        self.knownPersonCount = knownPersonCount
        self.photosWithPeople = photosWithPeople
        self.clusterCount = clusterCount
        self.multiPhotoClusterCount = multiPhotoClusterCount
        self.largestClusterSize = largestClusterSize
        self.totalOutfitSplits = totalOutfitSplits
        self.specialLandscapeThreshold = specialLandscapeThreshold
        self.duration = duration
        self.photosFromCache = photosFromCache
    }

    init(records: [PhotoRecord],
         faceClusters: [FaceCluster],
         clusters: [PhotoCluster],
         outfitSplitsByDay: [Date: Int],
         specialLandscapeThreshold: Double,
         duration: Duration,
         fromCache: Int) {

        self.totalPhotos = records.count
        self.specialLandscapeThreshold = specialLandscapeThreshold
        self.duration = duration
        self.photosFromCache = fromCache

        // Tiers, each with its reason breakdown.
        var summaries: [TierSummary] = []
        for tier in [Tier.tier1, .tier2, .tier3Protected] {
            let members = records.filter { $0.tier == tier }
            var reasonCounts: [TierReason: Int] = [:]
            for member in members { reasonCounts[member.reason, default: 0] += 1 }
            let reasons = reasonCounts
                .sorted { $0.value > $1.value }
                .map { (reason: $0.key, count: $0.value) }
            summaries.append(TierSummary(tier: tier,
                                          count: members.count,
                                          byteSize: members.reduce(0) { $0 + $1.byteSize },
                                          reasons: reasons))
        }
        self.tiers = summaries

        // Day grouping (PRD §12, M1).
        let calendar = Calendar.current
        var photosPerDay: [Date: Int] = [:]
        var locatedDays = Set<Date>()
        for record in records {
            guard let day = record.dayStart(calendar: calendar) else { continue }
            photosPerDay[day, default: 0] += 1
            if record.location != nil { locatedDays.insert(day) }
        }

        var clustersPerDay: [Date: Int] = [:]
        for cluster in clusters {
            guard let date = cluster.date else { continue }
            clustersPerDay[calendar.startOfDay(for: date), default: 0] += 1
        }

        self.days = photosPerDay.keys.sorted().map { day in
            DaySummary(day: day,
                       photoCount: photosPerDay[day] ?? 0,
                       clusterCount: clustersPerDay[day] ?? 0,
                       outfitSplitCount: outfitSplitsByDay[day] ?? 0,
                       hasLocation: locatedDays.contains(day))
        }

        // People.
        self.faceClusterCount = faceClusters.count
        self.knownPersonCount = faceClusters.filter(\.isKnown).count
        self.photosWithPeople = records.filter(\.hasPeople).count

        // Clustering.
        self.clusterCount = clusters.count
        self.multiPhotoClusterCount = clusters.filter { $0.photoIds.count > 1 }.count
        self.largestClusterSize = clusters.map(\.photoIds.count).max() ?? 0
        self.totalOutfitSplits = outfitSplitsByDay.values.reduce(0, +)
    }

    // MARK: Text rendering

    /// Plain-text report, so M1's numbers can be read without the GUI and
    /// pasted into threshold-tuning notes (PRD §14).
    func plainText() -> String {
        var lines: [String] = []
        lines.append("PhotoCurator scan report")
        lines.append(String(repeating: "=", count: 48))
        lines.append("Photos analysed: \(totalPhotos.formatted())"
                     + " (\(photosFromCache.formatted()) from cache)")
        lines.append("Duration: \(formattedDuration)")
        lines.append("")

        lines.append("TIERS (dry run — nothing has been changed)")
        for summary in tiers {
            lines.append("  \(summary.tier.displayName): \(summary.count.formatted())"
                         + "  [\(summary.formattedSize)]")
            for entry in summary.reasons {
                lines.append("      \(entry.reason.displayName): \(entry.count.formatted())")
            }
        }
        lines.append("")

        lines.append("PEOPLE")
        lines.append("  Face clusters: \(faceClusterCount.formatted())")
        lines.append("  Known people: \(knownPersonCount.formatted())")
        lines.append("  Photos containing people: \(photosWithPeople.formatted())")
        lines.append("")

        lines.append("CLUSTERING")
        lines.append("  Clusters: \(clusterCount.formatted())")
        lines.append("  With more than one photo: \(multiPhotoClusterCount.formatted())")
        lines.append("  Largest cluster: \(largestClusterSize.formatted()) photos")
        lines.append("  Extra clusters from outfit splitting: \(totalOutfitSplits.formatted())")
        lines.append("")

        lines.append("THRESHOLDS USED")
        lines.append(String(format: "  Special-landscape aesthetics: %.3f", specialLandscapeThreshold))
        lines.append("")

        lines.append("DAYS (\(days.count.formatted())) — \(daysWithLocation.formatted()) with GPS (\(daysTotal > 0 ? Int(100.0 * Double(daysWithLocation) / Double(daysTotal)) : 0)%)")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for day in days {
            var line = "  \(formatter.string(from: day.day)): "
                     + "\(day.photoCount.formatted()) photos, "
                     + "\(day.clusterCount.formatted()) clusters"
            if day.outfitSplitCount > 0 {
                line += ", +\(day.outfitSplitCount) from outfit split"
            }
            if !day.hasLocation { line += " (no GPS)" }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
