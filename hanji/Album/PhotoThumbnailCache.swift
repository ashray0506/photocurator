//  PhotoThumbnailCache.swift
//  Async PHAsset → NSImage loader with an in-memory cache.
//  If your project already has an image loader, keep yours and delete this file.

import AppKit
import Photos

@MainActor
final class PhotoThumbnailCache {
    static let shared = PhotoThumbnailCache()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 400 }

    func image(for localIdentifier: String, pointSize: CGSize, scale: CGFloat = 2) async -> NSImage? {
        let target = CGSize(width: max(pointSize.width, 1) * scale, height: max(pointSize.height, 1) * scale)
        let key = "\(localIdentifier)#\(Int(target.width))x\(Int(target.height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // one callback, no degraded first pass
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true       // iCloud originals

        let image: NSImage? = await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { img, _ in
                cont.resume(returning: img)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Warm the next spread so page turns never show empty frames.
    func preheat(_ ids: [String], pointSize: CGSize, scale: CGFloat = 2) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        manager.startCachingImages(for: list,
                                   targetSize: CGSize(width: pointSize.width * scale, height: pointSize.height * scale),
                                   contentMode: .aspectFill,
                                   options: nil)
    }
}
