import XCTest
@testable import PhotoCurator

/// PRD §13: "No photo in Tier 3 is ever deleted by any tier button."
/// Tier 3 protection is the safety property the whole app rests on, so these
/// tests assert it directly rather than through the UI.
final class TierAssignerTests: XCTestCase {

    private let assigner = TierAssigner()
    private var settings = CuratorSettings.default

    private func emptyContext(knownClusterIds: Set<Int> = [],
                              largestFaceCluster: [String: Int] = [:],
                              specialLandscapeThreshold: Double = 0.85,
                              confirmedKeepIds: Set<String> = [],
                              clusterAssignments: [String: Int] = [:],
                              keptPerCluster: [Int: Set<String>] = [:],
                              exactDuplicateClusters: Set<Int> = []) -> TierAssigner.Context {
        TierAssigner.Context(knownClusterIds: knownClusterIds,
                             largestFaceCluster: largestFaceCluster,
                             specialLandscapeThreshold: specialLandscapeThreshold,
                             confirmedKeepIds: confirmedKeepIds,
                             clusterAssignments: clusterAssignments,
                             keptPerCluster: keptPerCluster,
                             exactDuplicateClusters: exactDuplicateClusters)
    }

    /// A junk-looking photo is still protected if it is a favourite.
    func testFavoriteBeatsEverySinkSignal() {
        var record = PhotoRecord(id: "a")
        record.isFavorite = true
        // Every Tier 1 signal at once.
        record.media.isScreenshot = true
        record.junkType = .receipt
        record.junkConfidence = 1.0
        record.quality.brightness = 0.0
        record.quality.sharpness = 0.0
        record.quality.uniformity = 1.0

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
        XCTAssertEqual(result.reason, .favorite)
    }

    func testAlbumMembershipProtects() {
        var record = PhotoRecord(id: "b")
        record.inUserAlbum = true
        record.media.isScreenshot = true

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
        XCTAssertEqual(result.reason, .inUserAlbum)
    }

    func testEditedPhotoProtected() {
        var record = PhotoRecord(id: "c")
        record.isEdited = true
        record.quality.sharpness = 0.0

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
        XCTAssertEqual(result.reason, .edited)
    }

    /// PRD §6: a known person in frame protects the photo.
    func testKnownPersonProtectsBlurryPhoto() {
        var record = PhotoRecord(id: "d")
        record.faceClusterIds = [7]
        record.faceCount = 1
        record.quality.sharpness = 0.0   // would otherwise be Tier 1 blurry

        let result = assigner.assign(record,
                                     context: emptyContext(knownClusterIds: [7]),
                                     settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
        XCTAssertEqual(result.reason, .knownPerson)
    }

    /// PRD §6: high-scoring no-face landscapes are protected as special.
    func testSpecialLandscapeProtected() {
        var record = PhotoRecord(id: "e")
        record.quality.aesthetics = 0.93

        let result = assigner.assign(record,
                                     context: emptyContext(specialLandscapeThreshold: 0.85),
                                     settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
        XCTAssertEqual(result.reason, .specialLandscape)
    }

    /// PRD §6: "Keep all" locks photos out of future scans.
    func testConfirmedKeepLocksPhoto() {
        var record = PhotoRecord(id: "f")
        record.media.isScreenshot = true

        let result = assigner.assign(record,
                                     context: emptyContext(confirmedKeepIds: ["f"]),
                                     settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
    }

    /// A rescued photo stays rescued (PRD §6, review screen behaviour).
    func testUserOverrideProtects() {
        var record = PhotoRecord(id: "g")
        record.userOverride = true
        record.junkType = .document
        record.junkConfidence = 1.0

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
    }

    // MARK: Tier 1

    func testScreenshotIsTier1() {
        var record = PhotoRecord(id: "h")
        record.media.isScreenshot = true

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier1)
        XCTAssertEqual(result.reason, .screenshot)
    }

    func testAccidentalShotIsTier1() {
        var record = PhotoRecord(id: "i")
        record.quality.uniformity = 0.99

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier1)
        XCTAssertEqual(result.reason, .accidentalShot)
    }

    /// PRD §9.2: below the confidence floor we keep rather than classify.
    func testLowConfidenceJunkIsNotDeleted() {
        var record = PhotoRecord(id: "j")
        record.junkType = .receipt
        record.junkConfidence = 0.4           // below the 0.80 default floor
        record.quality.aesthetics = 0.6       // not a low-scoring landscape
        record.faceCount = 1                  // not a no-face landscape

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertNotEqual(result.tier, .tier1)
    }

    // MARK: Tier 2

    func testStrangerFocusedIsTier2() {
        var record = PhotoRecord(id: "k")
        record.faceCount = 1
        record.faceClusterIds = [42]
        record.quality.aesthetics = 0.5
        record.quality.sharpness = 0.5
        record.quality.brightness = 0.5

        let result = assigner.assign(record,
                                     context: emptyContext(knownClusterIds: [1],
                                                            largestFaceCluster: ["k": 42]),
                                     settings: settings)
        XCTAssertEqual(result.tier, .tier2)
        XCTAssertEqual(result.reason, .strangerFocused)
    }

    func testLowAestheticLandscapeIsTier2() {
        var record = PhotoRecord(id: "l")
        record.quality.aesthetics = 0.2
        record.quality.sharpness = 0.5
        record.quality.brightness = 0.5

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier2)
        XCTAssertEqual(result.reason, .lowAestheticLandscape)
    }

    func testNearDuplicateBeyondCapIsTier2() {
        var record = PhotoRecord(id: "m")
        record.quality.aesthetics = 0.5
        record.quality.sharpness = 0.5
        record.quality.brightness = 0.5
        record.faceCount = 1
        record.faceClusterIds = [3]

        let context = emptyContext(knownClusterIds: [],
                                   largestFaceCluster: [:],
                                   clusterAssignments: ["m": 1],
                                   keptPerCluster: [1: ["other"]])
        let result = assigner.assign(record, context: context, settings: settings)
        XCTAssertEqual(result.tier, .tier2)
        XCTAssertEqual(result.reason, .nearDuplicate)
    }

    /// A clean, ordinary photo of a person survives: it is neither junk nor a
    /// duplicate, so it must end up in the keep set the book is built from.
    func testOrdinaryPhotoSurvives() {
        var record = PhotoRecord(id: "n")
        record.quality.aesthetics = 0.6
        record.quality.sharpness = 0.6
        record.quality.brightness = 0.5
        record.faceCount = 1
        record.faceClusterIds = [5]

        let result = assigner.assign(record,
                                     context: emptyContext(knownClusterIds: [5],
                                                            largestFaceCluster: ["n": 5]),
                                     settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
    }

    /// Exhaustive sweep: no combination of junk signals can pull a protected
    /// photo out of Tier 3. This is the PRD §13 guarantee in test form.
    func testNoProtectedPhotoEverLeavesTier3() {
        let protections: [(String, (inout PhotoRecord) -> Void)] = [
            ("favorite", { $0.isFavorite = true }),
            ("album", { $0.inUserAlbum = true }),
            ("edited", { $0.isEdited = true }),
            ("override", { $0.userOverride = true }),
            ("knownPerson", { $0.faceClusterIds = [9]; $0.faceCount = 1 })
        ]

        for (name, applyProtection) in protections {
            for uniformity in [0.0, 1.0] {
                for brightness in [0.0, 0.5] {
                    for sharpness in [0.0, 0.5] {
                        for screenshot in [true, false] {
                            var record = PhotoRecord(id: "sweep")
                            applyProtection(&record)
                            record.quality.uniformity = uniformity
                            record.quality.brightness = brightness
                            record.quality.sharpness = sharpness
                            record.media.isScreenshot = screenshot
                            record.junkType = .receipt
                            record.junkConfidence = 1.0

                            let context = emptyContext(knownClusterIds: [9],
                                                       clusterAssignments: ["sweep": 1],
                                                       keptPerCluster: [1: []],
                                                       exactDuplicateClusters: [1])
                            let result = assigner.assign(record, context: context, settings: settings)
                            XCTAssertEqual(result.tier, .tier3Protected,
                                           "\(name) photo escaped Tier 3")
                        }
                    }
                }
            }
        }
    }

    // MARK: Unmeasured signals (PRD §9.2)

    /// Regression: a photo whose pixels could not be decoded has no measured
    /// sharpness or brightness. Treating those as 0 made it look maximally
    /// dark and blurry, so it was queued for deletion — the opposite of
    /// "when unsure, keep". An unmeasured photo must be protected.
    func testUnanalysablePhotoIsProtectedNotDeleted() {
        var record = PhotoRecord(id: "unmeasured")
        // Nothing measured: every pixel signal stays nil.
        XCTAssertNil(record.quality.sharpness)
        XCTAssertNil(record.quality.brightness)
        XCTAssertTrue(record.quality.isUnmeasured)

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier3Protected)
        XCTAssertEqual(result.reason, .lowConfidence)

        // And it must not be reported as dark, blurry or accidental.
        XCTAssertFalse(record.quality.isDark(below: settings.darkBrightnessMax))
        XCTAssertFalse(record.quality.isBlurry(below: settings.blurrySharpnessMax))
        XCTAssertFalse(record.quality.isAccidental(above: settings.accidentalUniformityMin))
    }

    /// Metadata-certain junk does not need pixel analysis, so a screenshot is
    /// still Tier 1 even when its pixels could not be measured. This is the
    /// ordering the uncertainty guard must preserve.
    func testUnmeasuredScreenshotIsStillTier1() {
        var record = PhotoRecord(id: "shot")
        record.media.isScreenshot = true
        XCTAssertTrue(record.quality.isUnmeasured)

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier1)
        XCTAssertEqual(result.reason, .screenshot)
    }

    /// A measured-but-genuinely-dark photo must still be caught, so the fix
    /// above did not simply disable the dark check.
    func testMeasuredDarkPhotoIsStillTier1() {
        var record = PhotoRecord(id: "dark")
        record.quality.brightness = 0.01
        record.quality.sharpness = 0.5
        record.quality.uniformity = 0.1

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier1)
        XCTAssertEqual(result.reason, .extremelyDark)
    }

    func testMeasuredBlurryPhotoIsStillTier1() {
        var record = PhotoRecord(id: "blur")
        record.quality.brightness = 0.5
        record.quality.sharpness = 0.01
        record.quality.uniformity = 0.1

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertEqual(result.tier, .tier1)
        XCTAssertEqual(result.reason, .extremelyBlurry)
    }

    /// An unscored landscape is not evidence of a low-scoring one.
    func testUnscoredLandscapeIsNotTier2() {
        var record = PhotoRecord(id: "land")
        record.quality.brightness = 0.5
        record.quality.sharpness = 0.5
        record.quality.uniformity = 0.1
        // aesthetics deliberately left nil.

        let result = assigner.assign(record, context: emptyContext(), settings: settings)
        XCTAssertNotEqual(result.reason, .lowAestheticLandscape)
    }

    // MARK: Threshold helper

    func testSpecialLandscapeThresholdUsesNoFacePhotosOnly() {
        var records: [PhotoRecord] = []
        for i in 0..<10 {
            var record = PhotoRecord(id: "no-face-\(i)")
            record.quality.aesthetics = Double(i) / 10.0
            records.append(record)
        }
        // A high-scoring photo *with* a face must not shift the landscape bar.
        var withFace = PhotoRecord(id: "face")
        withFace.faceCount = 1
        withFace.quality.aesthetics = 1.0
        records.append(withFace)

        settings.specialLandscapePercentile = 0.85
        let threshold = TierAssigner.specialLandscapeThreshold(for: records, settings: settings)
        XCTAssertLessThan(threshold, 1.0)
        XCTAssertGreaterThan(threshold, 0.5)
    }
}
