import Foundation
import Vision
import CoreImage
import os

/// All Vision work for one photo (PRD §3, §5).
///
/// Requests are created per call rather than reused: VNRequest objects are not
/// safe to share across concurrent handlers, and the analysis pipeline runs
/// several photos at once.
struct VisionAnalyzer: Sendable {

    struct FaceObservation {
        var boundingBox: CGRect       // normalised, Vision coordinates
        var captureQuality: Double?
        var featurePrint: Data?       // for library-wide clustering
        /// Fraction of the frame this face occupies.
        var area: Double { Double(boundingBox.width * boundingBox.height) }
    }

    struct Result {
        var featurePrint: Data?
        var aesthetics: Double?
        var faces: [FaceObservation] = []
        var bodyCount = 0
        var junkType: JunkType?
        var junkConfidence: Double = 0
    }

    private let log = Logger(subsystem: "app.photocurator", category: "vision")

    /// Scene-classification labels that mean "not a photo worth keeping"
    /// (PRD §5.3). Vision's taxonomy gives us these directly.
    private static let junkLabels: [String: JunkType] = [
        "text": .document,
        "document": .document,
        "paper": .document,
        "receipt": .receipt,
        "whiteboard": .whiteboard,
        "blackboard": .whiteboard,
        "screenshot": .screenshot,
        "menu": .document,
        "business_card": .document,
        "poster": .meme,
        "envelope": .document,
        "book_jacket": .document
    ]

    func analyze(ciImage: CIImage, settings: CuratorSettings) -> Result {
        var result = Result()
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:])

        let featureRequest = VNGenerateImageFeaturePrintRequest()
        let faceRectRequest = VNDetectFaceRectanglesRequest()
        let faceQualityRequest = VNDetectFaceCaptureQualityRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        let classifyRequest = VNClassifyImageRequest()

        // Aesthetics is deliberately absent here: on macOS 15+ it is an
        // async-only request (see `aesthetics(ciImage:)`) and does not fit this
        // synchronous handler batch.
        let requests: [VNRequest] = [
            featureRequest, faceRectRequest, faceQualityRequest,
            humanRequest, classifyRequest
        ]

        do {
            try handler.perform(requests)
        } catch {
            log.error("Vision batch failed: \(error.localizedDescription)")
            return result
        }

        // Scene feature print, the basis of duplicate detection (PRD §5.5).
        if let observation = featureRequest.results?.first as? VNFeaturePrintObservation {
            result.featurePrint = FeaturePrintStore.encode(observation)
        }

        // Faces: rectangles merged with capture quality by index.
        let qualityObservations = faceQualityRequest.results ?? []
        let rectObservations = faceRectRequest.results ?? []
        for (index, face) in rectObservations.enumerated() {
            var observation = FaceObservation(boundingBox: face.boundingBox)
            if index < qualityObservations.count {
                observation.captureQuality = qualityObservations[index].faceCaptureQuality.map(Double.init)
            }
            result.faces.append(observation)
        }

        result.bodyCount = humanRequest.results?.count ?? 0

        // Junk classification. PRD §9.2: below the confidence floor we do not
        // classify, which leaves the photo to be kept.
        if let classifications = classifyRequest.results {
            for classification in classifications {
                guard let type = Self.junkLabels[classification.identifier] else { continue }
                let confidence = Double(classification.confidence)
                if confidence >= settings.junkConfidenceMin, confidence > result.junkConfidence {
                    result.junkType = type
                    result.junkConfidence = confidence
                }
            }
        }

        return result
    }

    /// Aesthetics score on macOS 15+, normalised to 0...1.
    ///
    /// The request reports roughly -1...1, where negative means badly composed
    /// or technically poor; we map that onto the 0...1 range the rest of the
    /// pipeline and `CuratorSettings` assume.
    @available(macOS 15.0, *)
    func aesthetics(ciImage: CIImage) async -> Double? {
        do {
            let request = CalculateImageAestheticsScoresRequest()
            let observation = try await request.perform(on: ciImage)
            let raw = Double(observation.overallScore)
            return max(0, min(1, (raw + 1) / 2))
        } catch {
            log.error("Aesthetics request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Feature print of a sub-region, used for torso crops (PRD §5.6).
    func featurePrint(of ciImage: CIImage, in normalisedRect: CGRect) -> Data? {
        let extent = ciImage.extent
        guard !extent.isInfinite else { return nil }

        let pixelRect = CGRect(x: extent.origin.x + normalisedRect.origin.x * extent.width,
                               y: extent.origin.y + normalisedRect.origin.y * extent.height,
                               width: normalisedRect.width * extent.width,
                               height: normalisedRect.height * extent.height)
            .intersection(extent)
        guard pixelRect.width >= 8, pixelRect.height >= 8 else { return nil }

        let cropped = ciImage.cropped(to: pixelRect)
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(ciImage: cropped, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                return nil
            }
            return FeaturePrintStore.encode(observation)
        } catch {
            return nil
        }
    }

    /// Distance between two stored feature prints, 0 (identical) upward.
    static func featurePrintDistance(_ a: Data?, _ b: Data?) -> Float? {
        FeaturePrintStore.distance(a, b)
    }
}
