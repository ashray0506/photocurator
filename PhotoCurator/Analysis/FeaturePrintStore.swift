import Foundation
import Vision
import os

/// Persists Vision feature prints so a rescan can compare photos without
/// re-running Vision (PRD §13: rescans under 2 minutes).
///
/// `VNFeaturePrintObservation.data` is only the raw float vector: it carries no
/// element type or count, and there is no public initialiser to rebuild an
/// observation from it, so `computeDistance` cannot be used on a round-tripped
/// vector. Instead we archive the whole observation, which conforms to
/// `NSSecureCoding`, and let Vision compute distances on the decoded objects.
enum FeaturePrintStore {

    private static let log = Logger(subsystem: "app.photocurator", category: "featureprint")

    static func encode(_ observation: VNFeaturePrintObservation) -> Data? {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: observation,
                                                    requiringSecureCoding: true)
        } catch {
            log.error("Could not archive feature print: \(error.localizedDescription)")
            return nil
        }
    }

    static func decode(_ data: Data?) -> VNFeaturePrintObservation? {
        guard let data else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: data)
        } catch {
            log.error("Could not read feature print: \(error.localizedDescription)")
            return nil
        }
    }

    /// Vision's own distance metric. Lower means more similar; 0 is identical.
    /// Returns nil when either print is missing or the two are incomparable
    /// (different revisions or element counts), which callers treat as
    /// "not similar" so an unknown never causes a deletion.
    static func distance(_ a: Data?, _ b: Data?) -> Float? {
        guard let left = decode(a), let right = decode(b) else { return nil }
        var distance: Float = 0
        do {
            try left.computeDistance(&distance, to: right)
            return distance
        } catch {
            return nil
        }
    }

    /// Distance between two already-decoded observations, for the clustering
    /// hot loop where decoding once per photo matters.
    static func distance(_ left: VNFeaturePrintObservation,
                         _ right: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try left.computeDistance(&distance, to: right)
            return distance
        } catch {
            return nil
        }
    }
}
