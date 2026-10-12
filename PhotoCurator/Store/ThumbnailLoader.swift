import Foundation
import Photos
import SwiftUI

/// Loads and caches thumbnails for the tier review preview grid (PRD §6).
///
/// `PHCachingImageManager` rather than `PHImageManager`: the grid shows 60
/// photos and the user can rescue any of them, so cells scroll and
/// start/stop being visible repeatedly. The caching manager is built for
/// exactly that access pattern.
@MainActor
final class ThumbnailLoader: ObservableObject {
    private let manager = PHCachingImageManager()
    private let options: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false  // on-device only (PRD §1)
        return options
    }()

    @Published private(set) var images: [String: Image] = [:]

    func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        manager.startCachingImages(for: assets, targetSize: targetSize,
                                   contentMode: .aspectFill, options: options)
    }

    func stopCaching(_ assets: [PHAsset], targetSize: CGSize) {
        manager.stopCachingImages(for: assets, targetSize: targetSize,
                                  contentMode: .aspectFill, options: options)
    }

    func load(_ asset: PHAsset, targetSize: CGSize) {
        guard images[asset.localIdentifier] == nil else { return }
        manager.requestImage(for: asset, targetSize: targetSize,
                             contentMode: .aspectFill, options: options) { [weak self] nsImage, _ in
            guard let self, let nsImage else { return }
            Task { @MainActor in
                self.images[asset.localIdentifier] = Image(nsImage: nsImage)
            }
        }
    }
}
