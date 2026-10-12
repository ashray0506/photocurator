import Foundation
import CoreImage
import Accelerate
import os

/// Sharpness, exposure and uniformity from the pixels (PRD §5.2).
///
/// Everything here works on a downscaled grayscale buffer: at the analysis
/// thumbnail size these are cheap enough to run on all 10k photos well inside
/// the PRD §13 budget.
struct ImageQualityAnalyzer: Sendable {

    private let log = Logger(subsystem: "app.photocurator", category: "quality")

    /// Laplacian variance, the standard blur estimator. A sharp photo has lots
    /// of high-frequency energy; a blurred one has very little.
    ///
    /// Returned normalised to roughly 0...1 by dividing by an empirical ceiling,
    /// so thresholds in `CuratorSettings` stay readable.
    func sharpness(gray: [Float], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count == width * height else { return 0 }

        // 3x3 Laplacian kernel.
        var kernel: [Float] = [0, 1, 0,
                               1, -4, 1,
                               0, 1, 0]
        var output = [Float](repeating: 0, count: gray.count)

        gray.withUnsafeBufferPointer { src in
            var srcBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress),
                                          height: vImagePixelCount(height),
                                          width: vImagePixelCount(width),
                                          rowBytes: width * MemoryLayout<Float>.size)
            output.withUnsafeMutableBufferPointer { dst in
                var dstBuffer = vImage_Buffer(data: dst.baseAddress,
                                              height: vImagePixelCount(height),
                                              width: vImagePixelCount(width),
                                              rowBytes: width * MemoryLayout<Float>.size)
                _ = vImageConvolve_PlanarF(&srcBuffer, &dstBuffer, nil, 0, 0,
                                           &kernel, 3, 3, 0,
                                           vImage_Flags(kvImageEdgeExtend))
            }
        }

        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_normalize(output, 1, nil, 1, &mean, &stdDev, vDSP_Length(output.count))
        let variance = Double(stdDev * stdDev)

        // Empirical ceiling: variance above this is unambiguously sharp.
        let ceiling = 0.012
        return min(1.0, variance / ceiling)
    }

    /// Mean luma and the fraction of pixels clipped to black or white.
    func exposure(gray: [Float]) -> (brightness: Double, clipped: Double) {
        guard !gray.isEmpty else { return (0.5, 0) }

        var mean: Float = 0
        vDSP_meanv(gray, 1, &mean, vDSP_Length(gray.count))

        let darkCutoff: Float = 0.02
        let brightCutoff: Float = 0.98
        var clippedCount = 0
        for value in gray where value <= darkCutoff || value >= brightCutoff {
            clippedCount += 1
        }

        return (Double(mean), Double(clippedCount) / Double(gray.count))
    }

    /// How close the image is to a single flat colour. Catches lens-covered and
    /// pocket shots (PRD §5.2), which are near-uniform black or grey.
    ///
    /// Computed as 1 minus normalised standard deviation, so a perfectly flat
    /// frame scores 1.0.
    func uniformity(gray: [Float]) -> Double {
        guard gray.count > 1 else { return 1 }
        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_normalize(gray, 1, nil, 1, &mean, &stdDev, vDSP_Length(gray.count))
        // stdDev of a 0...1 signal maxes out around 0.5 for a half-black,
        // half-white frame; scale against that.
        let normalised = min(1.0, Double(stdDev) / 0.35)
        return 1.0 - normalised
    }

    /// Coarse RGB histogram, used as the colour half of an outfit fingerprint
    /// (PRD §5.6). 4 bins per channel keeps it small and robust to lighting.
    func colorHistogram(ciImage: CIImage, context: CIContext, bins: Int = 4) -> [Float] {
        let extent = ciImage.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else {
            return [Float](repeating: 0, count: bins * 3)
        }

        let width = 32
        let height = 32
        let scaled = ciImage.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / extent.width,
            y: CGFloat(height) / extent.height))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            context.render(scaled,
                           toBitmap: raw.baseAddress!,
                           rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        var histogram = [Float](repeating: 0, count: bins * 3)
        let binWidth = 256 / bins
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                let bin = min(bins - 1, Int(pixels[i + channel]) / binWidth)
                histogram[channel * bins + bin] += 1
            }
        }

        let total = Float(width * height)
        if total > 0 {
            for i in histogram.indices { histogram[i] /= total }
        }
        return histogram
    }

    /// Converts a CIImage to a planar Float grayscale buffer for the
    /// Accelerate-based signals above.
    func grayscaleBuffer(from ciImage: CIImage,
                         context: CIContext,
                         maxDimension: Int) -> (pixels: [Float], width: Int, height: Int)? {
        let extent = ciImage.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }

        let scale = min(1.0, CGFloat(maxDimension) / max(extent.width, extent.height))
        let width = max(1, Int(extent.width * scale))
        let height = max(1, Int(extent.height * scale))

        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            context.render(scaled,
                           toBitmap: raw.baseAddress!,
                           rowBytes: width,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .L8,
                           colorSpace: CGColorSpaceCreateDeviceGray())
        }

        var floats = [Float](repeating: 0, count: bytes.count)
        vDSP_vfltu8(bytes, 1, &floats, 1, vDSP_Length(bytes.count))
        var scaleDiv: Float = 255.0
        vDSP_vsdiv(floats, 1, &scaleDiv, &floats, 1, vDSP_Length(floats.count))

        return (floats, width, height)
    }

    /// Distance between two colour histograms, 0 (identical) to 1.
    /// Used for outfit comparison in PRD §7.
    static func histogramDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        // Hellinger distance: well behaved for normalised histograms.
        var sum: Float = 0
        for i in a.indices {
            let diff = sqrt(a[i]) - sqrt(b[i])
            sum += diff * diff
        }
        return min(1.0, Double(sqrt(sum / 2)))
    }
}
