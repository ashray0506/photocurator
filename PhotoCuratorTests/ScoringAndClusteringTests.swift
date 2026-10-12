import XCTest
@testable import PhotoCurator

final class BestPhotoScorerTests: XCTestCase {

    private func makeRecord(_ id: String,
                            aesthetics: Double = 0.5,
                            sharpness: Double = 0.5,
                            brightness: Double = 0.45) -> PhotoRecord {
        var record = PhotoRecord(id: id)
        record.quality.aesthetics = aesthetics
        record.quality.sharpness = sharpness
        record.quality.brightness = brightness
        return record
    }

    /// PRD §7: the per-cluster cap limits how many photos survive a moment.
    func testKeepersRespectCap() {
        var settings = CuratorSettings.default
        settings.perClusterCap = 3
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: [])

        let cluster = (0..<10).map { makeRecord("p\($0)", aesthetics: Double($0) / 10) }
        let keepers = scorer.keepers(in: cluster)

        XCTAssertEqual(keepers.count, 3)
        // The three highest-scoring photos should be the survivors.
        XCTAssertTrue(keepers.contains("p9"))
        XCTAssertTrue(keepers.contains("p8"))
        XCTAssertTrue(keepers.contains("p7"))
    }

    func testClusterAtOrUnderCapLosesNothing() {
        var settings = CuratorSettings.default
        settings.perClusterCap = 3
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: [])

        let cluster = (0..<3).map { makeRecord("q\($0)") }
        XCTAssertEqual(scorer.keepers(in: cluster).count, 3)
    }

    /// PRD §8: "Disabling the model returns results identical to the generic
    /// scoring." A tasteScore present but the model off must change nothing.
    func testDisabledTasteModelIsIdenticalToGenericScoring() {
        var settings = CuratorSettings.default
        settings.tasteModelEnabled = false
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: [])

        var withTaste = makeRecord("r1", aesthetics: 0.4)
        withTaste.tasteScore = 1.0
        let withoutTaste = makeRecord("r2", aesthetics: 0.4)

        XCTAssertEqual(scorer.finalScore(withTaste),
                       scorer.finalScore(withoutTaste),
                       accuracy: 1e-9)
    }

    func testEnabledTasteModelShiftsRanking() {
        var settings = CuratorSettings.default
        settings.tasteModelEnabled = true
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: [])

        var liked = makeRecord("s1", aesthetics: 0.4)
        liked.tasteScore = 1.0
        var disliked = makeRecord("s2", aesthetics: 0.4)
        disliked.tasteScore = 0.0

        XCTAssertGreaterThan(scorer.finalScore(liked), scorer.finalScore(disliked))
    }

    /// PRD §7: presence of a known person boosts a photo.
    func testKnownPersonBoost() {
        let settings = CuratorSettings.default
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: [1])

        var known = makeRecord("t1")
        known.faceClusterIds = [1]
        known.faceCount = 1
        var stranger = makeRecord("t2")
        stranger.faceClusterIds = [2]
        stranger.faceCount = 1

        XCTAssertGreaterThan(scorer.qualityScore(known), scorer.qualityScore(stranger))
    }

    func testScoresStayInUnitRange() {
        let settings = CuratorSettings.default
        let scorer = BestPhotoScorer(settings: settings, knownClusterIds: [1])

        var best = makeRecord("u1", aesthetics: 1, sharpness: 1, brightness: 0.45)
        best.faceClusterIds = [1]
        best.quality.bestFaceQuality = 1.0
        let worst = makeRecord("u2", aesthetics: 0, sharpness: 0, brightness: 1.0)

        XCTAssertLessThanOrEqual(scorer.qualityScore(best), 1.0)
        XCTAssertGreaterThanOrEqual(scorer.qualityScore(worst), 0.0)
    }
}

final class FaceClustererTests: XCTestCase {

    /// PRD §5.4: known if it appears in >= N photos or spans >= 3 days.
    /// Faces with no usable print are skipped, which keeps strangers from
    /// being invented out of missing data.
    func testCandidatesWithoutPrintsProduceNoClusters() {
        let candidates = (0..<20).map {
            FaceClusterer.Candidate(photoId: "p\($0)", day: Date(), area: 0.1, featurePrint: nil)
        }
        let output = FaceClusterer().cluster(candidates, settings: .default)
        XCTAssertTrue(output.clusters.isEmpty)
        XCTAssertTrue(output.assignments.isEmpty)
    }
}

final class QualityAnalyzerTests: XCTestCase {

    private let analyzer = ImageQualityAnalyzer()

    /// A flat frame is the lens-covered / pocket-shot case (PRD §5.2).
    func testFlatImageIsMaximallyUniform() {
        let flat = [Float](repeating: 0.02, count: 64 * 64)
        XCTAssertEqual(analyzer.uniformity(gray: flat), 1.0, accuracy: 0.01)
    }

    func testNoisyImageIsNotUniform() {
        var generator = SystemRandomNumberGenerator()
        let noisy = (0..<(64 * 64)).map { _ in Float.random(in: 0...1, using: &generator) }
        XCTAssertLessThan(analyzer.uniformity(gray: noisy), 0.5)
    }

    func testDarkFrameReportsLowBrightness() {
        let dark = [Float](repeating: 0.01, count: 32 * 32)
        let exposure = analyzer.exposure(gray: dark)
        XCTAssertLessThan(exposure.brightness, 0.06)
        XCTAssertEqual(exposure.clipped, 1.0, accuracy: 0.01)
    }

    /// A hard edge has far more high-frequency energy than a flat field,
    /// which is exactly what the Laplacian variance measures.
    func testSharpEdgeScoresHigherThanFlatField() {
        let width = 64, height = 64
        var edge = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                edge[y * width + x] = x < width / 2 ? 0.0 : 1.0
            }
        }
        let flat = [Float](repeating: 0.5, count: width * height)

        let edgeSharpness = analyzer.sharpness(gray: edge, width: width, height: height)
        let flatSharpness = analyzer.sharpness(gray: flat, width: width, height: height)

        XCTAssertGreaterThan(edgeSharpness, flatSharpness)
        XCTAssertEqual(flatSharpness, 0.0, accuracy: 0.001)
    }

    func testHistogramDistanceIsZeroForIdenticalHistograms() {
        let histogram: [Float] = [0.25, 0.25, 0.25, 0.25]
        XCTAssertEqual(ImageQualityAnalyzer.histogramDistance(histogram, histogram),
                       0.0, accuracy: 1e-6)
    }

    func testHistogramDistanceIsLargeForDisjointHistograms() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 0, 0, 1]
        XCTAssertGreaterThan(ImageQualityAnalyzer.histogramDistance(a, b), 0.9)
    }

    func testHistogramDistanceHandlesMismatchedLengths() {
        XCTAssertEqual(ImageQualityAnalyzer.histogramDistance([1, 0], [1, 0, 0]), 1.0)
    }
}

final class TorsoRectTests: XCTestCase {

    /// PRD §5.6: the torso crop sits below the face, inside the frame.
    func testTorsoSitsBelowFaceAndInsideFrame() {
        let face = CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2)
        let torso = LibraryScanner.torsoRect(below: face)
        XCTAssertNotNil(torso)
        guard let torso else { return }

        XCTAssertLessThanOrEqual(torso.maxY, face.minY + 0.0001)
        XCTAssertGreaterThanOrEqual(torso.minX, 0)
        XCTAssertGreaterThanOrEqual(torso.minY, 0)
        XCTAssertLessThanOrEqual(torso.maxX, 1.0001)
    }

    /// A face at the very bottom of the frame has no torso visible.
    func testFaceAtBottomOfFrameHasNoTorso() {
        let face = CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.2)
        XCTAssertNil(LibraryScanner.torsoRect(below: face))
    }
}

final class ScanReportTests: XCTestCase {

    func testReportCountsTiersAndReasons() {
        var records: [PhotoRecord] = []
        for i in 0..<5 {
            var record = PhotoRecord(id: "t1-\(i)")
            record.tier = .tier1
            record.reason = .screenshot
            record.byteSize = 1000
            records.append(record)
        }
        for i in 0..<3 {
            var record = PhotoRecord(id: "t2-\(i)")
            record.tier = .tier2
            record.reason = .nearDuplicate
            records.append(record)
        }
        var protected = PhotoRecord(id: "t3")
        protected.tier = .tier3Protected
        protected.reason = .favorite
        records.append(protected)

        let report = ScanReport(records: records,
                                faceClusters: [],
                                clusters: [],
                                outfitSplitsByDay: [:],
                                specialLandscapeThreshold: 0.8,
                                duration: .seconds(1),
                                fromCache: 0)

        XCTAssertEqual(report.totalPhotos, 9)
        XCTAssertEqual(report.tiers.first { $0.tier == .tier1 }?.count, 5)
        XCTAssertEqual(report.tiers.first { $0.tier == .tier1 }?.byteSize, 5000)
        XCTAssertEqual(report.tiers.first { $0.tier == .tier2 }?.count, 3)
        XCTAssertEqual(report.tiers.first { $0.tier == .tier3Protected }?.count, 1)
        XCTAssertEqual(report.tiers.first { $0.tier == .tier1 }?.reasons.first?.reason, .screenshot)
    }

    /// Regression: `daysWithLocation`/`daysTotal` must reflect every day in
    /// the library, not just whatever a truncated UI list happens to show.
    /// A real bug: ReportView showed the oldest 60 days first, and in a
    /// decades-spanning library those are often the least GPS-tagged, which
    /// made a well-covered library look GPS-less at a glance. The overall
    /// stat must stay correct regardless of how any view slices `days`.
    func testDaysWithLocationCountsEveryDayNotJustAVisibleSlice() {
        var records: [PhotoRecord] = []
        let calendar = Calendar.current
        // Three old days, no GPS.
        for offset in 0..<3 {
            var record = PhotoRecord(id: "old-\(offset)")
            record.creationDate = calendar.date(byAdding: .year, value: -40 + offset, to: Date())
            records.append(record)
        }
        // Two recent days, with GPS.
        for offset in 0..<2 {
            var record = PhotoRecord(id: "recent-\(offset)")
            record.creationDate = calendar.date(byAdding: .day, value: -offset, to: Date())
            record.latitude = 37.5
            record.longitude = 127.0
            records.append(record)
        }

        let report = ScanReport(records: records, faceClusters: [], clusters: [],
                                outfitSplitsByDay: [:], specialLandscapeThreshold: 0.8,
                                duration: .seconds(1), fromCache: 0)

        XCTAssertEqual(report.daysTotal, 5)
        XCTAssertEqual(report.daysWithLocation, 2)
    }

    /// PRD §12, M1: the report must state how many extra clusters outfit
    /// splitting created, per day.
    func testReportSurfacesOutfitSplits() {
        let day = Calendar.current.startOfDay(for: Date())
        var record = PhotoRecord(id: "a")
        record.creationDate = day.addingTimeInterval(3600)

        let report = ScanReport(records: [record],
                                faceClusters: [],
                                clusters: [],
                                outfitSplitsByDay: [day: 4],
                                specialLandscapeThreshold: 0.8,
                                duration: .seconds(1),
                                fromCache: 0)

        XCTAssertEqual(report.totalOutfitSplits, 4)
        XCTAssertEqual(report.days.first?.outfitSplitCount, 4)
        XCTAssertTrue(report.plainText().contains("outfit splitting"))
    }

    func testEmptyReportRenders() {
        XCTAssertFalse(ScanReport.empty.plainText().isEmpty)
    }
}
