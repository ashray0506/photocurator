import Foundation
import Photos
import os

/// Read-only access to the Photos library (PRD §4.1).
///
/// M1 deliberately contains no deletion code at all: there is no call to
/// `PHAssetChangeRequest.deleteAssets` anywhere in this milestone, so no code
/// path can remove a photo. Deletion arrives in M5 behind the tier buttons.
final class PhotoLibraryService: Sendable {

    enum AccessError: Error, LocalizedError {
        case denied
        case limited
        case restricted

        var errorDescription: String? {
            switch self {
            case .denied:
                return "PhotoCurator needs access to your Photos library. Grant it in System Settings › Privacy & Security › Photos."
            case .limited:
                return "PhotoCurator has access to only some photos. It needs full library access to find duplicates across your whole library."
            case .restricted:
                return "Photos access is restricted on this Mac, possibly by a device policy."
            }
        }
    }

    private let log = Logger(subsystem: "app.photocurator", category: "library")

    // MARK: Authorization

    var currentStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Requests full library access. `.readWrite` is requested now (rather than
    /// `.addOnly`) so the user grants once, before M5 needs delete rights.
    ///
    /// Checks `currentStatus` first and only calls
    /// `PHPhotoLibrary.requestAuthorization` when access genuinely hasn't
    /// been decided yet (`.notDetermined`). That call is documented to be
    /// a no-op once a decision already exists — no new prompt — but this
    /// app runs it on every single launch via the Trip Wrap-Up background
    /// rescan (`PhotoCuratorApp.swift`'s launch `.task`), and was reported
    /// as showing the access prompt "too often". Skipping the call
    /// entirely once status is already settled removes any dependency on
    /// that documented behaviour actually holding on every macOS version/
    /// build, rather than relying on it silently doing the right thing.
    @discardableResult
    func requestAccess() async throws -> PHAuthorizationStatus {
        let existing = currentStatus
        let status: PHAuthorizationStatus
        if existing == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = existing
        }
        switch status {
        case .authorized: return status
        case .limited: throw AccessError.limited
        case .denied: throw AccessError.denied
        case .restricted: throw AccessError.restricted
        case .notDetermined: throw AccessError.denied
        @unknown default: throw AccessError.denied
        }
    }

    // MARK: Enumeration

    /// Every image asset in the library, newest last so day grouping is in order.
    func fetchAllImageAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = true   // we need the leftovers to tier them
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    /// Set of localIdentifiers that belong to at least one *user-created* album.
    /// Tier 3 protects these (PRD §6), so we resolve it once up front rather
    /// than querying per photo.
    func userAlbumMembership() -> Set<String> {
        var ids = Set<String>()
        let types: [(PHAssetCollectionType, PHAssetCollectionSubtype)] = [
            (.album, .albumRegular),            // albums the user made
            (.album, .albumSyncedAlbum),
            (.album, .albumMyPhotoStream),
            (.album, .albumCloudShared)
        ]
        for (type, subtype) in types {
            let collections = PHAssetCollection.fetchAssetCollections(with: type,
                                                                      subtype: subtype,
                                                                      options: nil)
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                assets.enumerateObjects { asset, _, _ in
                    ids.insert(asset.localIdentifier)
                }
            }
        }
        // Smart albums are *not* included: "Recents" or "Screenshots" are not a
        // signal that the user curated anything.
        log.notice("\(ids.count) assets belong to a user album")
        return ids
    }

    /// Maps PhotoKit metadata onto a fresh record (PRD §5.1). Analysis fills
    /// in the rest.
    func makeRecord(from asset: PHAsset, inUserAlbum: Bool) -> PhotoRecord {
        var record = PhotoRecord(id: asset.localIdentifier)
        record.modificationDate = asset.modificationDate
        record.creationDate = asset.creationDate
        record.latitude = asset.location?.coordinate.latitude
        record.longitude = asset.location?.coordinate.longitude
        record.isFavorite = asset.isFavorite
        record.pixelWidth = asset.pixelWidth
        record.pixelHeight = asset.pixelHeight
        record.inUserAlbum = inUserAlbum

        let subtypes = asset.mediaSubtypes
        record.media.isScreenshot = subtypes.contains(.photoScreenshot)
        record.media.isLivePhoto = subtypes.contains(.photoLive)
        record.media.isPanorama = subtypes.contains(.photoPanorama)
        record.media.isHDR = subtypes.contains(.photoHDR)
        record.media.isBurst = asset.burstIdentifier != nil

        return record
    }

    /// Whether the asset has user edits. PhotoKit exposes this through the
    /// presence of an adjustment resource rather than a flag.
    func isEdited(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains { $0.type == .adjustmentData }
    }

    /// Byte size, used for the "disk space freed" estimate on review screens.
    func byteSize(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        for resource in resources where resource.type == .photo {
            if let size = resource.value(forKey: "fileSize") as? Int64 { return size }
        }
        return 0
    }
}
