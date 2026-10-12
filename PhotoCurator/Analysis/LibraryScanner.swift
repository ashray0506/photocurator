import Foundation
import Photos
import CoreImage
import Vision
import os

/// Drives the whole M1 pipeline (PRD §5): metadata, quality, junk, people,
/// fingerprints, clustering, tier assignment, report.
///
/// Resumable and cached: analysed photos are written to the cache in batches,
/// so a cancelled scan keeps its progress and a rescan only touches photos
/// whose modification date changed (PRD §4.3, §13).
///
/// **This milestone performs no deletion.** It assigns tiers and reports them.
@MainActor
final class LibraryScanner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case requestingAccess
        case fetchingAssets
        case analyzing(done: Int, total: Int)
        case clusteringFaces
        case clusteringScenes
        case assigningTiers
        case finished
        case cancelled
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .requestingAccess: return "Requesting Photos access…"
            case .fetchingAssets: return "Reading your library…"
            case .analyzing(let done, let total):
                return "Analysing photo \(done.formatted()) of \(total.formatted())…"
            case .clusteringFaces: return "Grouping people…"
            case .clusteringScenes: return "Finding duplicates…"
            case .assigningTiers: return "Sorting into tiers…"
            case .finished: return "Scan complete"
            case .cancelled: return "Scan cancelled"
            case .failed(let message): return "Scan failed: \(message)"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: ScanReport?
    @Published var settings: CuratorSettings = .default

    /// Every analysed photo, kept so tier review screens (PRD §6) can work
    /// with individual records: previewing, rescuing and deleting. The
    /// report above is just the aggregate view of this same array.
    @Published private(set) var records: [PhotoRecord] = []

    let deletionService = PhotoDeletionService()

    /// Kept alongside `records` purely so a rescue or deletion can rebuild
    /// the report's clustering/face stats without a full rescan — these are
    /// not derivable from `records` alone (PRD §12's cluster and outfit-split
    /// counts come from the clusters themselves, not the photos in them).
    private var lastFaceClusters: [FaceCluster] = []
    private var lastClusters: [PhotoCluster] = []
    private var lastOutfitSplitsByDay: [Date: Int] = [:]

    private let library = PhotoLibraryService()
    private let quality = ImageQualityAnalyzer()
    private let vision = VisionAnalyzer()
    let cache: AnalysisCache?
    private let log = Logger(subsystem: "app.photocurator", category: "scanner")

    /// One shared CIContext. Creating one per photo is expensive and leaks GPU
    /// memory under concurrency.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var task: Task<Void, Never>?

    init() {
        do {
            cache = try AnalysisCache()
        } catch {
            cache = nil
            Logger(subsystem: "app.photocurator", category: "scanner")
                .error("Cache unavailable, scanning without it: \(error.localizedDescription)")
        }
    }

    var isRunning: Bool {
        switch phase {
        case .idle, .finished, .cancelled, .failed: return false
        default: return true
        }
    }

    func cancel() {
        task?.cancel()
    }

    func start() {
        guard !isRunning else { return }
        task = Task { await run() }
    }

    // MARK: Tier review (PRD §6)

    /// All currently-analysed photos in a given tier, newest-captured first,
    /// so preview grids and deletion operate on the live set rather than a
    /// stale snapshot from the moment the report was built.
    func photos(in tier: Tier) -> [PhotoRecord] {
        records.filter { $0.tier == tier }
    }

    /// Rescues one photo into Tier 3 for this photo only (PRD §6: "tap to
    /// rescue an individual photo"). Persisted immediately so the rescue
    /// survives a rescan even if the user quits before scanning again.
    func rescue(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].userOverride = true
        records[index].tier = .tier3Protected
        records[index].reason = .favorite
        try? cache?.save([records[index]])
        rebuildReport()
    }

    /// Locks Tier 3 photos out of future scans (PRD §6: "Keep all").
    /// Tier 3 is never deletable, so this only affects whether the cache
    /// flags them `confirmed_keep`; it changes no tier assignment.
    func confirmKeepAll(in tier: Tier) {
        guard tier == .tier3Protected else { return }
        let ids = photos(in: tier).map(\.id)
        try? cache?.confirmKeep(ids: ids)
    }

    /// Deletes every photo currently in `tier`. Delegates the actual
    /// PhotoKit call to `PhotoDeletionService`, which independently refuses
    /// to touch anything tiered as protected — this method's own guard is
    /// the first line of defense, that refusal is the second.
    ///
    /// On success, removes the deleted photos from the in-memory `records`
    /// and rebuilds the report so the UI reflects the new counts without
    /// requiring a full rescan.
    func deleteAll(in tier: Tier,
                   progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        guard tier != .tier3Protected else { return }
        let targets = photos(in: tier)
        guard !targets.isEmpty else { return }

        try await deletionService.delete(targets, cache: cache, progress: progress)

        let deletedIds = Set(targets.map(\.id))
        records.removeAll { deletedIds.contains($0.id) }
        rebuildReport()
    }

    /// Recomputes the published report from the current `records` array,
    /// without a rescan. Used after a rescue or deletion changes counts.
    ///
    /// Clustering/face stats come from the last scan's cluster arrays, which
    /// are unaffected by a rescue or a within-tier deletion (both only ever
    /// touch Tier 1/2 members, and clusters are not re-run until the next
    /// scan) — PRD §12's outfit-split and cluster counts are not derivable
    /// from `records` alone.
    private func rebuildReport() {
        guard let previous = report else { return }
        report = ScanReport(records: records,
                            faceClusters: lastFaceClusters,
                            clusters: lastClusters,
                            outfitSplitsByDay: lastOutfitSplitsByDay,
                            specialLandscapeThreshold: previous.specialLandscapeThreshold,
                            duration: previous.duration,
                            fromCache: previous.photosFromCache)
    }

    // MARK: Trips

    @Published private(set) var trips: [Trip] = []
    private let geocoder = PlaceGeocoder()

    /// Loads saved trips from the cache. Call once after init (or after a
    /// scan, harmlessly — trips are independent of scan results).
    func loadTrips() {
        trips = (try? cache?.loadTrips()) ?? []
    }

    /// Runs `TripDetector` over the current survivors and returns candidates
    /// that do not already overlap a saved trip's date range, so re-running
    /// detection after naming some trips does not re-offer the same range.
    /// Place segments (PRD §10.2) are computed here, geocoded only once the
    /// candidate is actually saved (`saveTrip`) — geocoding every candidate
    /// up front would fire network requests for trips the user never keeps.
    func detectTripCandidates(detector: TripDetector = TripDetector()) -> [TripDetector.Candidate] {
        let survivors = records.filter { $0.tier != .tier1 && $0.tier != .tier2 }
        let candidates = detector.detect(in: survivors, settings: settings)
        return candidates.filter { candidate in
            !trips.contains { trip in
                trip.startDay <= candidate.endDay && candidate.startDay <= trip.endDay
            }
        }
    }

    /// Confirms a candidate as a named trip and persists it. The caller
    /// (the naming sheet) has already resolved place names while the user
    /// was looking at the sheet, since it needs them anyway to suggest a
    /// name — `saveTrip` reuses that result instead of geocoding a second
    /// time.
    func saveTrip(name: String, candidate: TripDetector.Candidate,
                 placeSegmentsByDay: [String: [TripPlaceSegment]]) {
        let trip = Trip(name: name, startDay: candidate.startDay, endDay: candidate.endDay,
                        photoIds: candidate.photoIds, placeSegmentsByDay: placeSegmentsByDay)
        trips.insert(trip, at: 0)
        try? cache?.saveTrip(trip)
    }

    /// Reverse-geocodes every segment's centroid and converts to the
    /// persisted, dictionary-keyed shape `Trip` stores. Exposed so the
    /// naming sheet can resolve once and hand the result to `saveTrip`.
    func resolvePlaceNames(
        for segmentsByDay: [Date: [PlaceSegmenter.Segment]]
    ) async -> [String: [TripPlaceSegment]] {
        // Flatten to one ordered list so geocoding runs with one shared
        // concurrency cap across the whole trip, not per day.
        var flatSegments: [(day: Date, segment: PlaceSegmenter.Segment)] = []
        for (day, segments) in segmentsByDay {
            for segment in segments { flatSegments.append((day, segment)) }
        }

        let locations = flatSegments.map { $0.segment.centroid }
        var names: [PlaceGeocoder.PlaceName?] = []
        // Geocode only the segments that actually have a centroid; keep
        // positions aligned so results can be zipped back afterward.
        let locatable = locations.compactMap { $0 }
        let resolved = await geocoder.names(for: locatable)
        var resolvedIterator = resolved.makeIterator()
        for location in locations {
            names.append(location != nil ? resolvedIterator.next() : nil)
        }

        var result: [String: [TripPlaceSegment]] = [:]
        for (index, entry) in flatSegments.enumerated() {
            let placeName: String?
            if case .resolved(let name) = names[index] { placeName = name } else { placeName = nil }
            let stored = TripPlaceSegment(id: entry.segment.id.uuidString,
                                          placeName: placeName,
                                          startDate: entry.segment.startDate,
                                          endDate: entry.segment.endDate,
                                          photoIds: entry.segment.photoIds)
            result[Trip.dayKey(entry.day), default: []].append(stored)
        }
        for key in result.keys {
            result[key]?.sort { $0.startDate < $1.startDate }
        }
        return result
    }

    func renameTrip(id: String, to newName: String) {
        guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
        trips[index].name = newName
        try? cache?.saveTrip(trips[index])
    }

    func deleteTrip(id: String) {
        trips.removeAll { $0.id == id }
        try? cache?.deleteTrip(id: id)
    }

    /// The trip's photos as live records, in capture order, for the day view
    /// and PDF export.
    func photos(in trip: Trip) -> [PhotoRecord] {
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return trip.photoIds
            .compactMap { byId[$0] }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    // MARK: Pipeline

    private func run() async {
        let clock = ContinuousClock()
        let started = clock.now

        do {
            phase = .requestingAccess
            try await library.requestAccess()

            phase = .fetchingAssets
            let assets = library.fetchAllImageAssets()
            let albumMembers = library.userAlbumMembership()
            let confirmedKeep = (try? cache?.confirmedKeepIds()) ?? []
            let cached = (try? cache?.loadAll()) ?? [:]

            var assetList: [PHAsset] = []
            assetList.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in assetList.append(asset) }

            guard !assetList.isEmpty else {
                report = ScanReport.empty
                phase = .finished
                return
            }

            // Analyse only what changed (PRD §13: rescan under 2 minutes).
            var records: [PhotoRecord] = []
            var needsAnalysis: [PHAsset] = []
            records.reserveCapacity(assetList.count)

            for asset in assetList {
                let id = asset.localIdentifier
                if let hit = cached[id], hit.modificationDate == asset.modificationDate {
                    var record = hit
                    // Album membership and favourites are cheap and can change
                    // without touching the asset's modification date.
                    record.isFavorite = asset.isFavorite
                    record.inUserAlbum = albumMembers.contains(id)
                    records.append(record)
                } else {
                    needsAnalysis.append(asset)
                }
            }

            log.notice("\(records.count) photos from cache, \(needsAnalysis.count) to analyse")

            // Analyse the remainder concurrently.
            phase = .analyzing(done: 0, total: needsAnalysis.count)
            let fresh = try await analyze(needsAnalysis, albumMembers: albumMembers)
            records.append(contentsOf: fresh)

            try Task.checkCancellation()

            // People (PRD §5.4).
            phase = .clusteringFaces
            let faceOutput = FaceClusterer().cluster(faceCandidates(from: records),
                                                      settings: settings)
            let knownIds = Set(faceOutput.clusters.filter(\.isKnown).map(\.id))
            for index in records.indices {
                let id = records[index].id
                records[index].faceClusterIds = faceOutput.assignments[id] ?? []
                records[index].largestFaceClusterId = faceOutput.largestFaceCluster[id]
            }

            try Task.checkCancellation()

            // Similarity clustering over non-protected photos (PRD §7).
            phase = .clusteringScenes
            let clusterable = records.filter {
                !$0.isFavorite && !$0.inUserAlbum && !$0.isEdited
                && !confirmedKeep.contains($0.id)
                && !$0.faceClusterIds.contains(where: { knownIds.contains($0) })
            }
            let clusterOutput = SimilarityClusterer().cluster(clusterable, settings: settings)

            // Best photos per cluster.
            let scorer = BestPhotoScorer(settings: settings, knownClusterIds: knownIds)
            let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            var keptPerCluster: [Int: Set<String>] = [:]
            var exactDuplicateClusters = Set<Int>()

            for cluster in clusterOutput.clusters {
                let members = cluster.photoIds.compactMap { byId[$0] }
                keptPerCluster[cluster.id] = scorer.keepers(in: members)
                if isExactDuplicateCluster(members) {
                    exactDuplicateClusters.insert(cluster.id)
                }
            }

            try Task.checkCancellation()

            // Tier assignment (PRD §6).
            phase = .assigningTiers
            let context = TierAssigner.Context(
                knownClusterIds: knownIds,
                largestFaceCluster: faceOutput.largestFaceCluster,
                specialLandscapeThreshold: TierAssigner.specialLandscapeThreshold(
                    for: records, settings: settings),
                confirmedKeepIds: confirmedKeep,
                clusterAssignments: clusterOutput.assignments,
                keptPerCluster: keptPerCluster,
                exactDuplicateClusters: exactDuplicateClusters)

            records = TierAssigner().assign(records, context: context, settings: settings)

            for index in records.indices {
                records[index].clusterId = clusterOutput.assignments[records[index].id]
            }

            // Persist and report.
            try? cache?.save(records)
            try? cache?.prune(keeping: Set(records.map(\.id)))

            let elapsed = clock.now - started
            let finishedReport = ScanReport(records: records,
                                faceClusters: faceOutput.clusters,
                                clusters: clusterOutput.clusters,
                                outfitSplitsByDay: clusterOutput.outfitSplitsByDay,
                                specialLandscapeThreshold: context.specialLandscapeThreshold,
                                duration: elapsed,
                                fromCache: records.count - fresh.count)

            // Published last and together: the review screens key off
            // `self.records`, so they must never see a report without the
            // matching per-photo array behind it.
            self.records = records
            self.lastFaceClusters = faceOutput.clusters
            self.lastClusters = clusterOutput.clusters
            self.lastOutfitSplitsByDay = clusterOutput.outfitSplitsByDay
            report = finishedReport
            phase = .finished
            log.notice("Scan finished in \(elapsed.description)")

        } catch is CancellationError {
            phase = .cancelled
        } catch {
            log.error("Scan failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Per-photo analysis

    private func analyze(_ assets: [PHAsset],
                         albumMembers: Set<String>) async throws -> [PhotoRecord] {
        guard !assets.isEmpty else { return [] }

        let concurrency = max(2, min(settings.maxConcurrentAnalyses,
                                     ProcessInfo.processInfo.activeProcessorCount - 1))
        var results: [PhotoRecord] = []
        results.reserveCapacity(assets.count)
        var completed = 0
        var pendingSave: [PhotoRecord] = []

        // Bounded-concurrency task group: a plain group over 10k photos would
        // hold 10k decoded images in flight.
        try await withThrowingTaskGroup(of: PhotoRecord?.self) { group in
            var index = 0

            func addTask(_ asset: PHAsset) {
                let inAlbum = albumMembers.contains(asset.localIdentifier)
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    return await self.analyzeOne(asset, inUserAlbum: inAlbum)
                }
            }

            while index < min(concurrency, assets.count) {
                addTask(assets[index])
                index += 1
            }

            while let finished = try await group.next() {
                try Task.checkCancellation()

                if let record = finished {
                    results.append(record)
                    pendingSave.append(record)
                }
                completed += 1

                if completed % 25 == 0 || completed == assets.count {
                    phase = .analyzing(done: completed, total: assets.count)
                }

                // Batch writes keep a cancelled scan's progress (PRD §4.3).
                if pendingSave.count >= 250 {
                    try? cache?.save(pendingSave)
                    pendingSave.removeAll(keepingCapacity: true)
                }

                if index < assets.count {
                    addTask(assets[index])
                    index += 1
                }
            }
        }

        if !pendingSave.isEmpty { try? cache?.save(pendingSave) }
        return results
    }

    private func analyzeOne(_ asset: PHAsset, inUserAlbum: Bool) async -> PhotoRecord? {
        var record = library.makeRecord(from: asset, inUserAlbum: inUserAlbum)
        record.isEdited = library.isEdited(asset)
        record.byteSize = library.byteSize(of: asset)

        guard let ciImage = await loadImage(for: asset) else {
            // Unreadable photo: PRD §9.2 means keep. Leaving the record at its
            // default Tier 3 does exactly that.
            log.error("Could not load image data for \(asset.localIdentifier, privacy: .private)")
            return record
        }

        // Pixel-level signals.
        if let gray = quality.grayscaleBuffer(from: ciImage,
                                              context: ciContext,
                                              maxDimension: settings.analysisThumbnailSize) {
            record.quality.sharpness = quality.sharpness(gray: gray.pixels,
                                                          width: gray.width,
                                                          height: gray.height)
            let exposure = quality.exposure(gray: gray.pixels)
            record.quality.brightness = exposure.brightness
            record.quality.clippedFraction = exposure.clipped
            record.quality.uniformity = quality.uniformity(gray: gray.pixels)
        } else {
            // Left nil: unmeasured, not zero. Tier rules treat that as "no
            // evidence of junk" rather than as a dark, blurry, flat frame.
        }

        // Vision signals.
        let visionResult = vision.analyze(ciImage: ciImage, settings: settings)
        record.featurePrint = visionResult.featurePrint
        record.junkType = visionResult.junkType
        record.junkConfidence = visionResult.junkConfidence
        record.faceCount = visionResult.faces.count
        record.bodyCount = visionResult.bodyCount
        record.quality.bestFaceQuality = visionResult.faces
            .compactMap(\.captureQuality).max()
        record.largestFaceArea = visionResult.faces.map(\.area).max() ?? 0

        if #available(macOS 15.0, *) {
            if let aesthetics = await vision.aesthetics(ciImage: ciImage) {
                record.quality.aesthetics = aesthetics
            }
        }

        // Face prints, for library-wide clustering.
        record.faceClusterIds = []
        var facePrints: [Data] = []
        for face in visionResult.faces {
            if let print = vision.featurePrint(of: ciImage, in: face.boundingBox) {
                facePrints.append(print)
            }
        }
        record.pendingFacePrints = zip(facePrints, visionResult.faces).map {
            PendingFace(featurePrint: $0.0, area: $0.1.area)
        }

        // Outfit prints: torso crop below each face (PRD §5.6).
        record.outfits = visionResult.faces.compactMap { face in
            guard let torso = Self.torsoRect(below: face.boundingBox) else { return nil }
            let cropped = Self.crop(ciImage, to: torso)
            let histogram = cropped.map {
                quality.colorHistogram(ciImage: $0, context: ciContext)
            } ?? []
            guard !histogram.isEmpty else { return nil }
            return OutfitPrint(histogram: histogram,
                               featurePrint: vision.featurePrint(of: ciImage, in: torso),
                               faceArea: face.area)
        }

        return record
    }

    /// Loads image data for analysis and decodes it at a reduced size.
    ///
    /// `PHImageManager.requestImage` is unavailable on macOS: its result
    /// handler yields an `NSImage`, which Swift cannot import from the Photos
    /// headers. `requestImageDataAndOrientation` is the AppKit-safe path, and
    /// handing the bytes straight to Core Image avoids an `NSImage` round-trip.
    ///
    /// Decoding is downscaled via Core Image's thumbnail hint: full-resolution
    /// decoding of 10k photos would dominate the PRD §13 time budget for no
    /// accuracy gain.
    private func loadImage(for asset: PHAsset) async -> CIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false   // on-device only (PRD §1)
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.version = .current               // honour user edits

        // PhotoKit can call the handler more than once; `withCheckedContinuation`
        // traps on a second resume, so resumption is gated to exactly once.
        let box = ResumeOnce()
        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                guard !cancelled, !failed, let data else {
                    if box.claim() { continuation.resume(returning: nil) }
                    return
                }
                if box.claim() { continuation.resume(returning: data) }
            }
        }

        guard let data else { return nil }

        let maxDimension = settings.analysisThumbnailSize
        guard let image = CIImage(data: data, options: [
            .applyOrientationProperty: true
        ]) else { return nil }

        // Downscale once, here, so every later signal works on the same buffer.
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = min(1.0, CGFloat(maxDimension) / max(extent.width, extent.height))
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: Helpers

    private func faceCandidates(from records: [PhotoRecord]) -> [FaceClusterer.Candidate] {
        records.flatMap { record in
            record.pendingFacePrints.map {
                FaceClusterer.Candidate(photoId: record.id,
                                        day: record.dayStart(),
                                        area: $0.area,
                                        featurePrint: $0.featurePrint)
            }
        }
    }

    /// True when every member is effectively the same frame (PRD §6, Tier 1).
    private func isExactDuplicateCluster(_ members: [PhotoRecord]) -> Bool {
        guard members.count > 1 else { return false }
        let reference = members[0].featurePrint
        for member in members.dropFirst() {
            guard let distance = FeaturePrintStore.distance(reference, member.featurePrint),
                  distance <= settings.exactDuplicateThreshold else {
                return false
            }
        }
        return true
    }

    /// Torso region below a face box, in Vision's bottom-left normalised space
    /// (PRD §5.6). Roughly 1.6 face-heights tall and 2 face-widths wide.
    nonisolated static func torsoRect(below face: CGRect) -> CGRect? {
        let width = min(1, face.width * 2.0)
        let height = min(1, face.height * 1.6)
        let x = max(0, face.midX - width / 2)
        let y = max(0, face.minY - height)
        let rect = CGRect(x: x, y: y, width: width, height: min(height, face.minY))
        return rect.height >= 0.03 && rect.width >= 0.03 ? rect : nil
    }

    nonisolated private static func crop(_ image: CIImage, to normalised: CGRect) -> CIImage? {
        let extent = image.extent
        guard !extent.isInfinite else { return nil }
        let rect = CGRect(x: extent.origin.x + normalised.origin.x * extent.width,
                          y: extent.origin.y + normalised.origin.y * extent.height,
                          width: normalised.width * extent.width,
                          height: normalised.height * extent.height)
            .intersection(extent)
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return image.cropped(to: rect)
    }
}

/// A face print awaiting library-wide clustering. Held on the record so a
/// cached photo can be re-clustered without re-running Vision.
struct PendingFace: Codable, Sendable {
    var featurePrint: Data?
    var area: Double
}

/// One-shot gate around a continuation that a callback may invoke repeatedly.
/// Internal (not file-private): both `LibraryScanner` and `PhotoBookExporter`
/// hit the same PhotoKit "handler may fire more than once" hazard.
final class ResumeOnce {
    private let lock = NSLock()
    private var used = false

    /// True exactly once, for the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
