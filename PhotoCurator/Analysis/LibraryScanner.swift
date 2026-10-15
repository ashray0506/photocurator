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
    @Published private(set) var records: [PhotoRecord] = [] {
        didSet {
            recordsById = nil
            coverPhotoByTripId.removeAll()
        }
    }

    /// Lazily (re)built id-lookup for `photos(in:)`. The sidebar calls that
    /// once per tier per trip (so 3-4 times per trip just to render),
    /// and with a 48k-photo library rebuilding a fresh dictionary on every
    /// call made the whole sidebar list visibly stutter/beachball — this
    /// caches it across calls, invalidated only when `records` itself
    /// changes (scan, rescue, delete), not on every render.
    private var recordsById: [String: PhotoRecord]?

    /// Memoised `coverPhoto(for:)` results. The value is itself optional
    /// (a trip whose photos have all been deleted has no cover), so this
    /// deliberately stores a double optional: the outer level means "not
    /// computed yet", the inner "computed, and there is none" — without
    /// that distinction a coverless trip would re-rank its whole photo
    /// set on every single grid render.
    private var coverPhotoByTripId: [String: PhotoRecord?] = [:]

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

    /// `ignoreCache: true` re-analyses every photo from scratch, as if the
    /// cache were empty — for when a user suspects a stale or wrong result
    /// and wants a from-scratch answer rather than trusting the cache's
    /// modification-date check. Slow at full library size by design (PRD
    /// §13's "rescan under 2 minutes" budget is explicitly for the normal,
    /// cache-assisted path); the cache itself is still written to
    /// afterward, so the next ordinary rescan is fast again.
    func start(ignoreCache: Bool = false) {
        guard !isRunning else { return }
        task = Task { await run(ignoreCache: ignoreCache) }
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
    /// Rescues a photo into Tier 3, returning the snapshot needed to undo
    /// it — the only kind of undo this app can make fully real. A delete
    /// has no equivalent: once `PhotoDeletionService` runs,
    /// `PHAssetChangeRequest.deleteAssets` has already moved the asset to
    /// Recently Deleted, and there is no PhotoKit call this app can make to
    /// bring it back — only the user, in Photos.app, can restore it. The
    /// toast for a delete must therefore point at Recently Deleted, never
    /// claim to undo the delete itself.
    @discardableResult
    func rescue(_ id: String) -> PhotoRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        let before = records[index]
        records[index].userOverride = true
        records[index].tier = .tier3Protected
        records[index].reason = .favorite
        try? cache?.save([records[index]])
        rebuildReport()
        return before
    }

    /// Reverts a rescue to its pre-rescue tier/reason — real undo, not a
    /// re-run of tier assignment (which could reclassify it differently if
    /// settings changed since).
    func undoRescue(_ previous: PhotoRecord) {
        guard let index = records.firstIndex(where: { $0.id == previous.id }) else { return }
        records[index] = previous
        try? cache?.save([previous])
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

    /// Same as `confirmKeepAll(in:)` but scoped to an explicit id set — used
    /// by the trip-scoped tier review so "Keep All" only locks this trip's
    /// Tier 3 photos, not the whole library's.
    func confirmKeep(ids: [String]) {
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
        try await deletePhotos(targets, progress: progress)
    }

    /// Deletes an arbitrary set of non-protected records — used by tier
    /// deletion (a whole tier) and by Trip Wrap-Up (a trip's junk subset).
    /// Always routes through here so `records` and the report stay in sync
    /// with what PhotoKit actually deleted; a caller that bypassed this
    /// would leave the deleted photos still showing in the UI until the
    /// next full scan.
    func deletePhotos(_ targets: [PhotoRecord],
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        guard !targets.isEmpty else { return }
        try await deletionService.delete(targets, cache: cache, progress: progress)

        let deletedIds = Set(targets.map(\.id))
        records.removeAll { deletedIds.contains($0.id) }
        rebuildReport()
    }

    /// Deletes Tier 3 "extras" within a trip — survivors the book did not
    /// choose and that are not protected for a real reason. Routes through
    /// `PhotoDeletionService.deleteTripExtras`, the one deliberate carve-out
    /// of "Tier 3 is never deleted" (see that method's doc comment for the
    /// reason-based guard that still backs it). Kept as its own method
    /// rather than a flag on `deletePhotos` so every other call site keeps
    /// the stricter, no-exceptions guard by construction.
    func deleteTripExtras(_ targets: [PhotoRecord],
                          progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        guard !targets.isEmpty else { return }
        try await deletionService.deleteTripExtras(targets, cache: cache, progress: progress)

        let deletedIds = Set(targets.map(\.id))
        records.removeAll { deletedIds.contains($0.id) }
        rebuildReport()
    }

    /// Finds every photo matching a Smart Delete rule set, across the
    /// whole library regardless of tier — unlike the trip-scoped Extras
    /// bucket, this is not confined to one trip.
    func smartDeleteMatches(_ query: SmartDeleteQuery) -> [PhotoRecord] {
        query.matchingPhotos(in: records, personIdByClusterId: personIdByClusterId)
    }

    /// Deletes a Smart Delete match set. Routes through
    /// `PhotoDeletionService.deleteSmartSelection` — see that method's doc
    /// comment for the safety floor (same reason-based Tier 3 carve-out as
    /// Extras, plus ordinary Tier 1/2 deletion, independently re-checked
    /// regardless of what the query already filtered).
    func deleteSmartSelection(_ targets: [PhotoRecord],
                              progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        guard !targets.isEmpty else { return }
        try await deletionService.deleteSmartSelection(targets, cache: cache, progress: progress)

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

    // MARK: Home locations

    @Published private(set) var homeLocations: [HomeLocation] = []

    /// Loads saved home locations (auto-detected and/or manually added).
    /// Call once at launch, mirroring `loadTrips`.
    func loadHomeLocations() {
        homeLocations = (try? cache?.loadHomeLocations()) ?? []
    }

    /// Runs `HomeLocationDetector` over the current survivors and persists
    /// what it finds. Reverse-geocodes each detected centroid so the home
    /// list reads as a place name, not raw coordinates.
    func detectHomeLocations() {
        Task {
            let candidates = HomeLocationDetector().detect(in: records, settings: settings)
            guard !candidates.isEmpty else {
                try? cache?.markHomeDetectionRan()
                return
            }

            let names = await geocoder.names(for: candidates.map(\.location))
            let yearFormatter = DateFormatter()
            yearFormatter.dateFormat = "yyyy"

            for (index, candidate) in candidates.enumerated() {
                let placeName: String?
                if case .resolved(let name, _, _) = names[index] { placeName = name } else { placeName = nil }

                let startYear = yearFormatter.string(from: candidate.firstDay)
                let endYear = yearFormatter.string(from: candidate.lastDay)
                let yearRange = startYear == endYear ? startYear : "\(startYear)–\(endYear)"
                let resolvedName = placeName.map { "\($0) (\(yearRange))" } ?? "Home \(index + 1) (\(yearRange))"

                let home = HomeLocation(name: resolvedName,
                                        latitude: candidate.location.coordinate.latitude,
                                        longitude: candidate.location.coordinate.longitude,
                                        radius: settings.homeRadius,
                                        isAutoDetected: true,
                                        distinctDayCount: candidate.dayCount,
                                        firstDay: candidate.firstDay,
                                        lastDay: candidate.lastDay)
                homeLocations.append(home)
                try? cache?.saveHomeLocation(home)
            }
            try? cache?.markHomeDetectionRan()
            log.notice("Auto-detected \(candidates.count) home location(s)")
        }
    }

    /// Adds a home the user entered manually (PRD requirement: auto-detect
    /// with override — some homes, like a previous city, may need to be
    /// added by hand).
    func addHomeLocation(name: String, latitude: Double, longitude: Double, radius: Double? = nil) {
        let home = HomeLocation(name: name, latitude: latitude, longitude: longitude,
                                radius: radius ?? settings.homeRadius, isAutoDetected: false)
        homeLocations.append(home)
        try? cache?.saveHomeLocation(home)
    }

    func updateHomeLocation(_ home: HomeLocation) {
        guard let index = homeLocations.firstIndex(where: { $0.id == home.id }) else { return }
        homeLocations[index] = home
        try? cache?.saveHomeLocation(home)
    }

    func removeHomeLocation(id: String) {
        homeLocations.removeAll { $0.id == id }
        try? cache?.deleteHomeLocation(id: id)
    }

    // MARK: People

    @Published private(set) var people: [Person] = []
    /// This session's `FaceCluster.id` -> stable `Person.id`, so the
    /// People screen and a photo's `faceClusterIds` can find each other.
    /// Rebuilt every scan (cluster ids are only valid within one scan),
    /// never persisted itself — `Person.id` is what's stable, this is
    /// just the current session's lookup into it.
    @Published private(set) var personIdByClusterId: [Int: String] = [:]

    func loadPeople() {
        people = (try? cache?.loadPeople()) ?? []
    }

    /// Runs after face clustering in every scan: matches this session's
    /// known clusters against saved `Person` records (new ones created as
    /// needed) and persists the result. See `PersonMatcher`'s doc comment
    /// for why this two-pass design exists instead of `FaceClusterer`
    /// tracking identity itself.
    private func matchPeople(faceOutput: FaceClusterer.Output, knownIds: Set<Int>, records: [PhotoRecord]) {
        var bestPrintByCluster: [Int: (area: Double, print: Data)] = [:]
        var thumbnailByCluster: [Int: (area: Double, photoId: String, box: CGRect?)] = [:]

        for record in records {
            for face in record.pendingFacePrints {
                guard let print = face.featurePrint else { continue }
                // Which cluster this specific face belongs to isn't
                // tracked per-face, only per-photo (`faceClusterIds`) —
                // for a photo with exactly one known cluster membership
                // this face's print is unambiguous; multi-person photos
                // just contribute to whichever of their clusters has not
                // yet seen a larger-area face, which is an acceptable
                // approximation for picking a representative exemplar.
                for clusterId in record.faceClusterIds where knownIds.contains(clusterId) {
                    if face.area > (bestPrintByCluster[clusterId]?.area ?? -1) {
                        bestPrintByCluster[clusterId] = (face.area, print)
                        thumbnailByCluster[clusterId] = (face.area, record.id, face.boundingBox)
                    }
                }
            }
        }

        guard !bestPrintByCluster.isEmpty else { return }

        let clusterPrints = bestPrintByCluster.mapValues(\.print)
        let thumbnailPhotoId = thumbnailByCluster.mapValues(\.photoId)
        let thumbnailFaceBox = thumbnailByCluster.mapValues(\.box)
        var statsByCluster: [Int: (photoCount: Int, dayCount: Int)] = [:]
        for cluster in faceOutput.clusters where knownIds.contains(cluster.id) {
            statsByCluster[cluster.id] = (cluster.photoCount, cluster.dayCount)
        }

        let matches = PersonMatcher().match(clusterPrints: clusterPrints,
                                            clusterStats: statsByCluster,
                                            thumbnailPhotoId: thumbnailPhotoId,
                                            thumbnailFaceBox: thumbnailFaceBox,
                                            existingPeople: people,
                                            settings: settings)

        var updatedPeople = people
        var mapping: [Int: String] = [:]
        for match in matches {
            mapping[match.clusterId] = match.person.id
            try? cache?.savePerson(match.person)
            if let index = updatedPeople.firstIndex(where: { $0.id == match.person.id }) {
                updatedPeople[index] = match.person
            } else {
                updatedPeople.append(match.person)
            }
        }
        people = updatedPeople
        personIdByClusterId = mapping
    }

    /// User-assigned name, persisted immediately. `nil`/empty clears back
    /// to the generic "Person seen N times" placeholder.
    func renamePerson(id: String, to newName: String) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        people[index].name = trimmed.isEmpty ? nil : trimmed
        try? cache?.savePerson(people[index])
    }

    /// Manually folds `losers` into `keep` — the fix for the one thing
    /// automatic matching can never fully solve on its own: clustering a
    /// real person's face correctly is a best effort (reported directly:
    /// "random faces and same faces are shown differently... many times
    /// its completely wrong"), so there needs to be a way to correct it
    /// by hand rather than only ever rescan-and-hope.
    ///
    /// Combines both people's representative prints (capped the same way
    /// `PersonMatcher` caps them, so future rescans keep matching well),
    /// sums their stats, keeps `keep`'s name/thumbnail if set else falls
    /// back to a loser's, deletes each loser from the cache, and — this
    /// session only, until the next rescan re-derives it from the merged
    /// prints — repoints every cluster id that mapped to a loser so
    /// `photos(for:)` immediately shows the combined set.
    func mergePeople(keep keepId: String, into losers: [String]) {
        guard var keeper = people.first(where: { $0.id == keepId }) else { return }
        var mergedLoserIds: [String] = []

        for loserId in losers where loserId != keepId {
            guard let loser = people.first(where: { $0.id == loserId }) else { continue }

            keeper.representativeFeaturePrints.append(contentsOf: loser.representativeFeaturePrints)
            keeper.photoCount += loser.photoCount
            keeper.dayCount = max(keeper.dayCount, loser.dayCount)
            if keeper.name == nil { keeper.name = loser.name }
            if keeper.thumbnailPhotoId == nil {
                keeper.thumbnailPhotoId = loser.thumbnailPhotoId
                keeper.thumbnailFaceBox = loser.thumbnailFaceBox
            }
            if let loserFirst = loser.firstSeen {
                keeper.firstSeen = min(keeper.firstSeen ?? loserFirst, loserFirst)
            }
            if let loserLast = loser.lastSeen {
                keeper.lastSeen = max(keeper.lastSeen ?? loserLast, loserLast)
            }

            for (clusterId, personId) in personIdByClusterId where personId == loserId {
                personIdByClusterId[clusterId] = keepId
            }
            mergedLoserIds.append(loserId)
        }

        if keeper.representativeFeaturePrints.count > PersonMatcher.maxStoredPrints {
            keeper.representativeFeaturePrints.removeFirst(
                keeper.representativeFeaturePrints.count - PersonMatcher.maxStoredPrints)
        }

        people.removeAll { mergedLoserIds.contains($0.id) }
        if let keepIndex = people.firstIndex(where: { $0.id == keepId }) {
            people[keepIndex] = keeper
        }
        try? cache?.savePerson(keeper)
        for loserId in mergedLoserIds {
            try? cache?.deletePerson(id: loserId)
        }
    }

    /// All photos whose largest or any face matches this person, from the
    /// current scan's records — mirrors `photos(in tier:)`'s pattern.
    ///
    /// Collects every cluster id this session mapped to the person, not
    /// just one: after `mergePeople`, two different clusters can both
    /// point at the same surviving `Person.id`, and showing only one of
    /// them would silently drop half the merged person's photos.
    func photos(for person: Person) -> [PhotoRecord] {
        let clusterIds = Set(personIdByClusterId.filter { $0.value == person.id }.keys)
        guard !clusterIds.isEmpty else { return [] }
        return records.filter { !Set($0.faceClusterIds).isDisjoint(with: clusterIds) }
    }

    // MARK: Trips

    @Published private(set) var trips: [Trip] = []
    private let geocoder = PlaceGeocoder()

    /// Loads saved trips from the cache. Call once after init (or after a
    /// scan, harmlessly — trips are independent of scan results).
    func loadTrips() {
        trips = (try? cache?.loadTrips()) ?? []
    }

    /// Whether a scan has ever completed before. Used to gate an automatic
    /// launch-time rescan (Trip Wrap-Up detection): never auto-scan on a
    /// genuinely first launch, where Photos access and the backup reminder
    /// must be granted/acknowledged first.
    var hasScannedBefore: Bool {
        cache?.hasAnyPhotos() ?? false
    }

    /// Runs `TripDetector` over the current survivors and returns candidates
    /// that do not already overlap a saved trip's date range, so re-running
    /// detection after naming some trips does not re-offer the same range.
    /// Days at a known home location (PRD requirement: not everything is a
    /// trip) are excluded before detection even runs. Place segments
    /// (PRD §10.2) are computed here, geocoded only once the candidate is
    /// actually saved (`saveTrip`) — geocoding every candidate up front
    /// would fire network requests for trips the user never keeps.
    func detectTripCandidates(detector: TripDetector = TripDetector()) -> [TripDetector.Candidate] {
        let survivors = records.filter { $0.tier != .tier1 && $0.tier != .tier2 }
        let candidates = detector.detect(in: survivors, settings: settings, homes: homeLocations)
        return candidates.filter { candidate in
            !trips.contains { trip in
                trip.startDay <= candidate.endDay && candidate.startDay <= trip.endDay
            }
        }
    }

    /// The "Trip Wrap-Up" moment: a trip that just ended, not yet saved, so
    /// the app can proactively offer to clean it up and draft its book
    /// while the trip is still fresh — the same pattern as Apple Photos'
    /// Memories or Google Photos' trip highlights.
    ///
    /// Requires `records` to already reflect the trip's photos, which means
    /// a scan must have run since returning — there is no detection without
    /// at least an incremental scan, since that is what populates `records`
    /// in the first place. The app's own incremental cache (PRD §13) keeps
    /// this cheap: a scan run days after the last one only analyses the
    /// handful of new photos, not the whole library again.
    func recentUnsavedTripCandidate(within days: Int = 4,
                                    detector: TripDetector = TripDetector()) -> TripDetector.Candidate? {
        Self.mostRecentCandidate(in: detectTripCandidates(detector: detector), within: days)
    }

    /// The selection logic alone, factored out so it is testable without a
    /// live Photos library or `@MainActor` scanner state: picks the
    /// latest-ending candidate that ended within the last `days` days, or
    /// nil if none qualifies.
    nonisolated static func mostRecentCandidate(in candidates: [TripDetector.Candidate],
                                                within days: Int, now: Date = Date()) -> TripDetector.Candidate? {
        // Compare at day granularity: `endDay` is always a start-of-day
        // timestamp (PhotoRecord.dayStart), but `now` carries a time of
        // day, so subtracting `days` from `now` directly can land a few
        // hours after a candidate's start-of-day cutoff and wrongly
        // exclude it. Truncating `now` to its own start-of-day first keeps
        // the comparison exact at exactly `days` days back.
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        return candidates
            .filter { $0.endDay >= cutoff }
            .max { $0.endDay < $1.endDay }
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

    /// Saves every currently-detected candidate automatically, with a
    /// best-guess name (geocoded place, or a date-range fallback when there
    /// is no GPS) — so trips simply appear in the list rather than needing
    /// an explicit tap-to-name-and-save per trip. Renaming afterward is the
    /// same `renameTrip` used everywhere else; this is purely about not
    /// requiring a gate before a trip exists at all.
    @discardableResult
    func autoSaveDetectedTrips(detector: TripDetector = TripDetector()) async -> [Trip] {
        let candidates = detectTripCandidates(detector: detector)
        var saved: [Trip] = []
        for candidate in candidates {
            let placeSegmentsByDay = await resolvePlaceNames(for: candidate.segmentsByDay)
            let stops = Self.namingStops(from: placeSegmentsByDay)
            let name = Trip.suggestedName(startDay: candidate.startDay, endDay: candidate.endDay,
                                          places: stops)
            let trip = Trip(name: name, startDay: candidate.startDay, endDay: candidate.endDay,
                            photoIds: candidate.photoIds, placeSegmentsByDay: placeSegmentsByDay)
            trips.insert(trip, at: 0)
            try? cache?.saveTrip(trip)
            saved.append(trip)
        }
        return saved
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
            var placeName: String?
            var city: String?
            var country: String?
            if case .resolved(let name, let resolvedCity, let resolvedCountry) = names[index] {
                placeName = name
                city = resolvedCity
                country = resolvedCountry
            }
            let stored = TripPlaceSegment(id: entry.segment.id.uuidString,
                                          placeName: placeName,
                                          city: city,
                                          country: country,
                                          latitude: entry.segment.centroid?.coordinate.latitude,
                                          longitude: entry.segment.centroid?.coordinate.longitude,
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

    /// Re-geocodes a trip's own photos and renames it with the current
    /// (country-aware) naming logic — for a trip saved before `country`
    /// existed on `TripPlaceSegment`, whose stored segments have
    /// `country == nil` and so can never produce a combined-city name
    /// without this. Re-segments from the trip's own `photoIds` rather
    /// than re-running `TripDetector` (boundaries don't need
    /// re-detecting, just the place names), and only touches this one
    /// trip's name and place segments — nothing else about it changes.
    func refreshTripName(id: String) async {
        guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
        let trip = trips[index]
        let calendar = Calendar.current
        let tripPhotos = photos(in: trip)
        let byDay = Dictionary(grouping: tripPhotos) { $0.dayStart(calendar: calendar) ?? trip.startDay }

        let segmenter = PlaceSegmenter()
        var segmentsByDay: [Date: [PlaceSegmenter.Segment]] = [:]
        for (day, dayPhotos) in byDay {
            segmentsByDay[day] = segmenter.segment(dayPhotos, settings: settings)
        }

        let placeSegmentsByDay = await resolvePlaceNames(for: segmentsByDay)
        let stops = Self.namingStops(from: placeSegmentsByDay)

        guard let freshIndex = trips.firstIndex(where: { $0.id == id }) else { return }
        trips[freshIndex].placeSegmentsByDay = placeSegmentsByDay
        trips[freshIndex].name = Trip.suggestedName(startDay: trip.startDay, endDay: trip.endDay, places: stops)
        try? cache?.saveTrip(trips[freshIndex])
    }

    func deleteTrip(id: String) {
        trips.removeAll { $0.id == id }
        try? cache?.deleteTrip(id: id)
    }

    /// The trip's photos as live records, in capture order, for the day view
    /// and PDF export.
    func photos(in trip: Trip) -> [PhotoRecord] {
        let byId: [String: PhotoRecord]
        if let cached = recordsById {
            byId = cached
        } else {
            byId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            recordsById = byId
        }
        return trip.photoIds
            .compactMap { byId[$0] }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    /// Tier 3 photos in this trip that the book did NOT choose and that
    /// are not protected for a real reason — the "kept because nothing
    /// flagged it, not because it's a favorite/person/edit/album member"
    /// bucket (`.keep`, `.lowConfidence`, `.specialLandscape`). Computes
    /// the book's full-trip selection (not just days a screen has already
    /// rendered — `selectedPhotos` is otherwise lazy per day) so this is
    /// always complete, then persists any day it had to compute so a
    /// later book-editor view sees the same selection, not a different
    /// random ranking.
    ///
    /// Deliberately NOT a `Tier` case: `Tier` is the persisted, tested
    /// safety boundary ("Tier 3 never deletable" — `TierAssignerTests`,
    /// `PhotoDeletionServiceTests`). This is a trip-scoped view computed
    /// on demand over the same photos, so that invariant for the real
    /// tiers stays intact; deleting through this bucket still goes
    /// through the one `PhotoDeletionService` call site and its own
    /// tier check, which rejects anything actually tier3-protected for a
    /// real reason even if this computation were ever wrong.
    nonisolated static let extrasEligibleReasons: Set<TierReason> = [.keep, .lowConfidence, .specialLandscape]

    func unselectedExtras(in trip: Trip) -> [PhotoRecord] {
        let tripPhotos = photos(in: trip)
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: tripPhotos) { $0.dayStart(calendar: calendar) ?? .distantPast }

        var chosenIds = Set<String>()
        for (day, dayPhotos) in byDay {
            let chosen = selectedPhotos(for: day, in: trip, dayPhotos: dayPhotos)
            chosenIds.formUnion(chosen.map(\.id))
        }

        return Self.filterExtras(tripPhotos, chosenIds: chosenIds)
    }

    /// The filtering decision alone, factored out for testability without a
    /// live scanner/trip/Photos access — mirrors `rankAndSelect`/`swapped`
    /// below, which do the same for the book-selection and swap logic.
    ///
    /// `!$0.hasPeople` is a second, independent guard beyond the reason
    /// check: `TierAssigner` only tags a photo `.knownPerson` when its face
    /// cluster clears `knownPersonMinPhotos` (recurs often enough in the
    /// library to be "known") — a person who appears in just a few photos
    /// (met once, a less-photographed relative) has a detected face but
    /// never gets that reason, and fell through to plain `.keep`. Before
    /// this bucket existed that was harmless (`.keep` just meant "stays in
    /// Tier 3 forever"); now that `.keep` can be offered for deletion here,
    /// any detected face or body — known or not — must stay out of this
    /// bucket regardless of reason.
    /// Builds `Trip.suggestedName`'s input from resolved place segments:
    /// city-level only ("Rome", never "I Municipio, Rome"), deduplicated,
    /// in first-seen order — the "minimum should be city" naming floor.
    /// Falls back to the fuller `placeName` only for a segment whose
    /// placemark had no locality/admin area at all, so a real stop is
    /// never silently dropped just because `city` came back nil.
    nonisolated static func namingStops(from placeSegmentsByDay: [String: [TripPlaceSegment]]) -> [Trip.PlaceStop] {
        var seen = Set<String>()
        var stops: [Trip.PlaceStop] = []
        for dayKey in placeSegmentsByDay.keys.sorted() {
            for segment in placeSegmentsByDay[dayKey] ?? [] {
                guard let label = segment.city ?? segment.placeName, seen.insert(label).inserted else { continue }
                stops.append(Trip.PlaceStop(name: label, country: segment.country))
            }
        }
        return stops
    }

    nonisolated static func filterExtras(_ tripPhotos: [PhotoRecord], chosenIds: Set<String>) -> [PhotoRecord] {
        tripPhotos.filter {
            $0.tier == .tier3Protected
            && !$0.hasPeople
            && extrasEligibleReasons.contains($0.reason)
            && !chosenIds.contains($0.id)
        }
    }

    // MARK: Book photo selection (PRD §10.4)

    /// The book's chosen photos for one day, computing and persisting a
    /// default selection the first time this day is seen. Ranks the whole
    /// day by `BestPhotoScorer.finalScore` (not per-cluster — a day may
    /// span several clusters) and keeps the top `bookPhotosPerDayMax`,
    /// never fewer than `bookPhotosPerDayMin` when that many photos exist.
    func selectedPhotos(for day: Date, in trip: Trip, dayPhotos: [PhotoRecord]) -> [PhotoRecord] {
        let key = Trip.dayKey(day)
        if let existingIds = trip.selectedPhotoIdsByDay[key], !existingIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: dayPhotos.map { ($0.id, $0) })
            let ordered = existingIds.compactMap { byId[$0] }
            if !ordered.isEmpty { return ordered }
        }

        let knownIds = Set(dayPhotos.flatMap(\.faceClusterIds))
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: knownIds)
        let chosen = Self.rankAndSelect(dayPhotos, scorer: scorer, settings: settings)

        persistSelection(chosen.map(\.id), for: day, in: trip)
        return chosen
    }

    /// The single best photo in a trip, for its Memories card cover —
    /// highest `BestPhotoScorer.finalScore` across the whole trip rather
    /// than its first photo chronologically (which is usually an arrival
    /// shot, not the one worth showing).
    ///
    /// Memoised per trip id: the Memories grid renders a card per trip,
    /// and ranking every photo of every trip on each SwiftUI re-render
    /// was exactly the shape of the stall that made the old sidebar
    /// unusable. Cleared whenever `records` change, alongside the other
    /// derived caches.
    func coverPhoto(for trip: Trip) -> PhotoRecord? {
        // `if let cached` would unwrap only the outer optional and treat a
        // cached-but-nil cover as a miss; this checks for the key itself.
        if let cached = coverPhotoByTripId[trip.id] { return cached }

        let tripPhotos = photos(in: trip)
        guard !tripPhotos.isEmpty else {
            coverPhotoByTripId[trip.id] = PhotoRecord?.none
            return nil
        }

        let knownIds = Set(tripPhotos.flatMap(\.faceClusterIds))
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: knownIds)
        let best = tripPhotos.max { scorer.finalScore($0) < scorer.finalScore($1) }
        coverPhotoByTripId[trip.id] = best
        return best
    }

    /// The ranking/selection decision alone (PRD §10.4: best 3 to 6 per
    /// day), factored out so it is testable without a live scanner or
    /// Photos library. Ranks the whole day by `scorer.finalScore` (not
    /// per-cluster — a day may span several clusters) and keeps the top
    /// `bookPhotosPerDayMax`, never fewer than `bookPhotosPerDayMin` when
    /// that many photos exist.
    nonisolated static func rankAndSelect(_ dayPhotos: [PhotoRecord], scorer: BestPhotoScorer,
                                          settings: CuratorSettings) -> [PhotoRecord] {
        guard !dayPhotos.isEmpty else { return [] }
        let target = min(settings.bookPhotosPerDayMax, max(settings.bookPhotosPerDayMin, dayPhotos.count))
        let ranked = dayPhotos.sorted { scorer.finalScore($0) > scorer.finalScore($1) }
        return Array(ranked.prefix(min(target, ranked.count)))
    }

    /// Swaps one chosen photo for another from the same day — the PRD
    /// §10.8 "swap any chosen photo for another" affordance. The incoming
    /// photo need not already be in the day's selection; it is simply
    /// substituted at the outgoing photo's position.
    func swapPhoto(_ outgoingId: String, for incomingId: String, day: Date, in trip: Trip) {
        let key = Trip.dayKey(day)
        guard let swapped = Self.swapped(in: trip.selectedPhotoIdsByDay[key] ?? [],
                                         outgoing: outgoingId, incoming: incomingId) else { return }
        persistSelection(swapped, for: day, in: trip)
    }

    /// The substitution alone, factored out for the same testability
    /// reason as `rankAndSelect`. Nil when the outgoing id is not actually
    /// in the current selection — a stale swap request should do nothing,
    /// not insert the incoming photo at an arbitrary position.
    nonisolated static func swapped(in ids: [String], outgoing: String, incoming: String) -> [String]? {
        guard let index = ids.firstIndex(of: outgoing) else { return nil }
        var result = ids
        result[index] = incoming
        return result
    }

    private func persistSelection(_ ids: [String], for day: Date, in trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].selectedPhotoIdsByDay[Trip.dayKey(day)] = ids
        try? cache?.saveTrip(trips[index])
    }

    // MARK: Page decoration (stickers, caption style)
    //
    // Purely cosmetic — drawn on top of the page at export time, same as a
    // caption. The underlying photos are never modified, per the product
    // requirement that source photos stay untouched.

    func addSticker(_ sticker: PageSticker, to day: Date, in trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].stickersByDay[Trip.dayKey(day), default: []].append(sticker)
        try? cache?.saveTrip(trips[index])
    }

    func removeSticker(id: String, from day: Date, in trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].stickersByDay[Trip.dayKey(day)]?.removeAll { $0.id == id }
        try? cache?.saveTrip(trips[index])
    }

    func moveSticker(id: String, to position: (x: Double, y: Double), day: Date, in trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        let key = Trip.dayKey(day)
        guard let stickerIndex = trips[index].stickersByDay[key]?.firstIndex(where: { $0.id == id }) else { return }
        trips[index].stickersByDay[key]?[stickerIndex].x = position.x
        trips[index].stickersByDay[key]?[stickerIndex].y = position.y
        try? cache?.saveTrip(trips[index])
    }

    func setCaptionStyle(_ style: PageCaptionStyle, for day: Date, in trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index].captionStyleByDay[Trip.dayKey(day)] = style
        try? cache?.saveTrip(trips[index])
    }

    // MARK: Pipeline

    private func run(ignoreCache: Bool = false) async {
        let clock = ContinuousClock()
        let started = clock.now

        do {
            phase = .requestingAccess
            try await library.requestAccess()

            phase = .fetchingAssets
            let assets = library.fetchAllImageAssets()
            let albumMembers = library.userAlbumMembership()
            let confirmedKeep = (try? cache?.confirmedKeepIds()) ?? []
            let cached = ignoreCache ? [:] : ((try? cache?.loadAll()) ?? [:])

            var assetList: [PHAsset] = []
            assetList.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in assetList.append(asset) }

            guard !assetList.isEmpty else {
                report = ScanReport.empty
                phase = .finished
                return
            }

            // Analyse only what changed (PRD §13: rescan under 2 minutes) —
            // unless `ignoreCache`, in which case `cached` is already empty
            // above and every asset falls through to `needsAnalysis` below.
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

            matchPeople(faceOutput: faceOutput, knownIds: knownIds, records: records)

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

            // Home detection runs once per library, not once per scan, so a
            // user's edits (renames, added/removed homes) are never
            // silently overwritten by a rescan.
            if homeLocations.isEmpty, cache?.homeDetectionHasRun() != true {
                detectHomeLocations()
            }

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
            PendingFace(featurePrint: $0.0, area: $0.1.area, boundingBox: $0.1.boundingBox)
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
    /// Normalised (0...1, Vision's bottom-left-origin coordinate space)
    /// bounding box of this face — for cropping a face-thumbnail in the
    /// People screen. Nil for faces analysed before this field existed;
    /// those simply fall back to the full photo thumbnail rather than a
    /// crop, same as any other missing-signal case in this app.
    var boundingBox: CGRect? = nil
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
