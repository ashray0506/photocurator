import Foundation
import PDFKit
import Photos
import AppKit

/// Exports a trip to a print-ready PDF (PRD §10.9), simplified:
///
/// - One page per day, a grid of that day's photos, a date header.
/// - No AI-written titles/captions (PRD §10.5 asks for these from an AI
///   model; deferred — it is a product decision about sending trip text to
///   the Anthropic API, not an engineering one, see PRD §14).
/// - No route map (PRD §10.6 asks for a MapKit snapshot per day; this
///   library has too little GPS coverage for it to be worth building yet —
///   see the scan report's near-universal "no GPS" days).
/// - Letter-ish page size at a fixed layout rather than the PRD's
///   configurable A4/8x10/square + bleed (PRD §14 open question).
///
/// Captions and route maps are the two biggest remaining gaps versus the
/// full PRD §10 book; this gets a usable, shareable PDF out the door first.
struct PhotoBookExporter {

    enum ExportError: Error, LocalizedError {
        case noPhotos
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noPhotos: return "This trip has no photos to export."
            case .writeFailed: return "Could not write the PDF file."
            }
        }
    }

    // US Letter at 72pt/inch. PRD §10.9 wants 300dpi print resolution and a
    // page-size choice (§14); this is a readable screen/print default, not
    // the final answer to that open question.
    private let pageSize = CGSize(width: 612, height: 792)
    private let margin: CGFloat = 36

    func export(trip: Trip, days: [(day: Date, photos: [PhotoRecord])]) async throws -> URL {
        guard !days.isEmpty else { throw ExportError.noPhotos }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw ExportError.writeFailed
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.writeFailed
        }

        drawCoverPage(context: context, mediaBox: mediaBox, trip: trip, days: days)

        for entry in days {
            let images = await loadFullImages(for: entry.photos)
            let placeNames = trip.segments(for: entry.day).compactMap(\.placeName)
            drawDayPage(context: context, mediaBox: mediaBox, day: entry.day,
                       placeNames: placeNames, images: images,
                       style: trip.captionStyle(for: entry.day),
                       stickers: trip.stickers(for: entry.day))
        }

        context.closePDF()

        let safeName = trip.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).pdf")
        do {
            try (pdfData as Data).write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
        return url
    }

    // MARK: Pages

    private func drawCoverPage(context: CGContext, mediaBox: CGRect, trip: Trip,
                               days: [(day: Date, photos: [PhotoRecord])]) {
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        let title = trip.name as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .bold)
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        title.draw(at: CGPoint(x: margin, y: mediaBox.height - margin - titleSize.height),
                  withAttributes: titleAttributes)

        let totalPhotos = days.reduce(0) { $0 + $1.photos.count }
        let subtitle = "\(days.count) days · \(totalPhotos) photos" as NSString
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.darkGray
        ]
        subtitle.draw(at: CGPoint(x: margin, y: mediaBox.height - margin - titleSize.height - 28),
                      withAttributes: subtitleAttributes)

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }

    private func drawDayPage(context: CGContext, mediaBox: CGRect, day: Date,
                             placeNames: [String], images: [NSImage],
                             style: PageCaptionStyle, stickers: [PageSticker]) {
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        let formatter = DateFormatter()
        formatter.dateFormat = style == .minimal ? "MMM d, yyyy" : "EEEE, MMMM d, yyyy"
        let title = (style == .minimal ? formatter.string(from: day).uppercased()
                                       : formatter.string(from: day)) as NSString
        let titleAttributes = Self.titleAttributes(for: style)
        let titleSize = title.size(withAttributes: titleAttributes)
        let titleY = mediaBox.height - margin - titleSize.height
        title.draw(at: CGPoint(x: margin, y: titleY), withAttributes: titleAttributes)

        // Place names (PRD §10.3), shown as a subtitle under the date when
        // any segment that day resolved to a name.
        var subtitleHeight: CGFloat = 0
        if !placeNames.isEmpty {
            let subtitle = placeNames.joined(separator: " · ") as NSString
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.darkGray
            ]
            let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
            subtitle.draw(at: CGPoint(x: margin, y: titleY - subtitleSize.height - 4),
                          withAttributes: subtitleAttributes)
            subtitleHeight = subtitleSize.height + 4
        }

        // Simple grid: up to 6 photos per page, 2 columns.
        let gridTop = titleY - subtitleHeight - 20
        let columns = 2
        let cellSpacing: CGFloat = 12
        let cellWidth = (mediaBox.width - margin * 2 - cellSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight: CGFloat = 200

        for (index, image) in images.prefix(6).enumerated() {
            let column = index % columns
            let row = index / columns
            let x = margin + CGFloat(column) * (cellWidth + cellSpacing)
            let y = gridTop - cellHeight - CGFloat(row) * (cellHeight + cellSpacing)
            guard y > margin else { break }

            let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
            drawAspectFit(image: image, in: rect)
        }

        // Stickers (decoration only — the photos above are drawn exactly
        // as loaded; nothing here modifies the source images).
        for sticker in stickers {
            drawSticker(sticker, in: mediaBox)
        }

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }

    /// Font/color per caption style preset. `.playful` is the "kids" look:
    /// rounded system font where available, warm accent color.
    private static func titleAttributes(for style: PageCaptionStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .classic:
            return [.font: NSFont.systemFont(ofSize: 20, weight: .semibold)]
        case .playful:
            let base = NSFont.systemFont(ofSize: 24, weight: .bold)
            let roundedDescriptor = base.fontDescriptor.withDesign(.rounded)
            let rounded = roundedDescriptor.flatMap { NSFont(descriptor: $0, size: 24) } ?? base
            return [.font: rounded, .foregroundColor: NSColor.systemOrange]
        case .minimal:
            return [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                   .foregroundColor: NSColor.secondaryLabelColor]
        }
    }

    private func drawSticker(_ sticker: PageSticker, in mediaBox: CGRect) {
        let fontSize: CGFloat = 36 * sticker.scale
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
        let text = sticker.emoji as NSString
        let size = text.size(withAttributes: attributes)
        // Stored position is normalised 0...1 from the top-left (how the
        // editor's SwiftUI canvas addresses it); PDF space is bottom-left,
        // so the y axis flips here.
        let point = CGPoint(x: CGFloat(sticker.x) * mediaBox.width - size.width / 2,
                            y: (1 - CGFloat(sticker.y)) * mediaBox.height - size.height / 2)
        text.draw(at: point, withAttributes: attributes)
    }

    private func drawAspectFit(image: NSImage, in rect: CGRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))
    }

    // MARK: Image loading

    /// Full-resolution images for print, loaded via `requestImageDataAndOrientation`
    /// — `PHImageManager.requestImage` is unavailable on macOS (its handler
    /// returns an `NSImage` the Swift importer cannot bring in from the
    /// Photos headers; see `LibraryScanner.loadImage`, which hit the same
    /// constraint during analysis).
    private func loadFullImages(for records: [PhotoRecord]) async -> [NSImage] {
        var images: [NSImage] = []
        for record in records {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
            guard let asset = result.firstObject else { continue }
            if let image = await loadImage(for: asset) { images.append(image) }
        }
        return images
    }

    private func loadImage(for asset: PHAsset) async -> NSImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.version = .current

        let box = ResumeOnce()
        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
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
        return NSImage(data: data)
    }
}
