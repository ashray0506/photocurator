import SwiftUI
import Photos

/// A cropped face thumbnail for a `Person` card — loads the full photo at
/// a modest target size, then crops to the stored face bounding box using
/// plain SwiftUI layout math rather than a server-side `CGImage` crop
/// (simpler, and the crop only ever needs to be as sharp as a small
/// avatar, not print quality).
struct FaceThumbnail: View {
    let photoId: String?
    let faceBox: CGRect?
    var size: CGFloat = 92

    @StateObject private var thumbnails = ThumbnailLoader()

    var body: some View {
        ZStack {
            if let photoId, let image = thumbnails.images[photoId] {
                cropped(image)
            } else {
                Circle().fill(Theme.accent.opacity(0.18))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task { load() }
    }

    @ViewBuilder
    private func cropped(_ image: Image) -> some View {
        if let faceBox {
            // Vision's bounding box is normalised (0...1) with a
            // bottom-left origin; SwiftUI's GeometryReader-free approach
            // here scales the whole image up so the face box fills the
            // frame, then offsets it so the box's centre lands at the
            // view's centre — a crop without a `GeometryReader` or a
            // `CGImage` round-trip.
            let scaleX = 1 / max(faceBox.width, 0.05)
            let scaleY = 1 / max(faceBox.height, 0.05)
            // A little headroom around the tight face box reads better
            // than an edge-to-edge crop (hair, chin aren't cut off).
            let padding: CGFloat = 1.6
            let scale = min(scaleX, scaleY) / padding

            let centerX = faceBox.midX
            // Flip Y: Vision's origin is bottom-left, SwiftUI's is top-left.
            let centerY = 1 - faceBox.midY

            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size * scale, height: size * scale)
                .offset(x: (0.5 - centerX) * size * scale,
                       y: (0.5 - centerY) * size * scale)
        } else {
            image.resizable().aspectRatio(contentMode: .fill)
        }
    }

    private func load() {
        guard let photoId else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil)
        guard let asset = result.firstObject else { return }
        thumbnails.load(asset, targetSize: CGSize(width: size * 6, height: size * 6))
    }
}
