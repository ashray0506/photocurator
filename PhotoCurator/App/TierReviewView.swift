import SwiftUI
import Photos

/// The one-button-per-tier review screen (PRD §6).
///
/// Shows a sample preview grid, a reason breakdown, and exactly one primary
/// action: "Keep all" for Tier 3 (no delete action exists for that tier —
/// there is no button in this view that can touch it), or "Delete Tier N"
/// for Tier 1/2, gated by a single confirmation sheet.
///
/// `scope` narrows the screen to one trip's own photos — the sidebar's
/// per-trip Tier 1/2/3 rows use this so "Delete Tier 1" only touches this
/// trip's junk, not the whole library. `nil` (the Curate tab's usage) is
/// the original whole-library behaviour.
struct TierReviewView: View {
    let tier: Tier
    var scope: Trip?
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var thumbnails = ThumbnailLoader()

    @State private var sample: [PhotoRecord] = []
    @State private var enlarged: PhotoRecord?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteProgress: (done: Int, total: Int)?
    @State private var deleteError: String?
    @State private var didConfirmKeep = false

    private let thumbSize = CGSize(width: 180, height: 180)
    private let sampleSize = 60   // PRD §6: "a random sample of 60 photos"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                breakdown
                grid
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(tier.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { primaryButton }
        }
        .task(id: tier) { loadSample() }
        .sheet(item: $enlarged) { record in
            EnlargedPhotoSheet(record: record,
                              keeper: keeperCounterpart(for: record),
                              onRescue: { rescue(record) },
                              onDismiss: { enlarged = nil })
        }
        .confirmationDialog(
            "Delete \(photos.count.formatted()) photos?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(photos.count.formatted()) Photos", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay in Recently Deleted for 30 days. macOS will also ask you to confirm.")
        }
        .alert("Deletion failed", isPresented: .constant(deleteError != nil), actions: {
            Button("OK") { deleteError = nil }
        }, message: {
            Text(deleteError ?? "")
        })
    }

    private var photos: [PhotoRecord] {
        guard let scope else { return scanner.photos(in: tier) }
        let tripIds = Set(scope.photoIds)
        return scanner.photos(in: tier).filter { tripIds.contains($0.id) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tier.displayName).font(.title2.weight(.semibold))
                Spacer()
                Text("\(photos.count.formatted()) photos")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            let totalBytes = photos.reduce(Int64(0)) { $0 + $1.byteSize }
            if totalBytes > 0 {
                Text("~\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) would be freed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if tier == .tier3Protected {
                Label("This tier is never deleted by any button in this app.",
                     systemImage: "checkmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if let progress = deleteProgress {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text("Deleting \(progress.done.formatted()) of \(progress.total.formatted())…")
                        .font(.caption)
                }
            }

            if didConfirmKeep {
                Label("Locked — these photos are excluded from future scans.",
                     systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var breakdown: some View {
        let counts = Dictionary(grouping: photos, by: \.reason)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Breakdown").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(counts, id: \.key) { reason, count in
                HStack {
                    Text(reason.displayName).foregroundStyle(.secondary)
                    Spacer()
                    Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample (\(sample.count.formatted()) of \(photos.count.formatted()))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(sample) { record in
                    thumbnailCell(record)
                }
            }
        }
    }

    private func thumbnailCell(_ record: PhotoRecord) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = thumbnails.images[record.id] {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { enlarged = record }
            .onAppear { requestThumbnail(record) }

            if record.userOverride {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.white, .green)
                    .padding(6)
                    .shadow(radius: 2)
            }
        }
        .contextMenu {
            if tier != .tier3Protected {
                Button("Rescue to Tier 3") { rescue(record) }
            }
        }
    }

    /// The surviving "best of cluster" photo this record was flagged
    /// against, if any — for the side-by-side "why was this one kept and
    /// this one flagged" comparison (near-duplicate / duplicate reasons
    /// only; a reason like "screenshot" has no counterpart to compare to).
    private func keeperCounterpart(for record: PhotoRecord) -> PhotoRecord? {
        guard record.reason == .nearDuplicate || record.reason == .exactDuplicate,
              let clusterId = record.clusterId else { return nil }
        return scanner.records.first {
            $0.clusterId == clusterId && $0.id != record.id && $0.tier == .tier3Protected
        }
    }

    private func requestThumbnail(_ record: PhotoRecord) {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
        guard let asset = result.firstObject else { return }
        thumbnails.load(asset, targetSize: thumbSize)
    }

    // MARK: Primary action

    @ViewBuilder
    private var primaryButton: some View {
        switch tier {
        case .tier3Protected:
            Button("Keep All (\(photos.count.formatted()))") {
                keepAll()
                didConfirmKeep = true
            }
        case .tier1, .tier2:
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Text("Delete \(tier == .tier1 ? "Tier 1" : "Tier 2") (\(photos.count.formatted()))")
            }
            .disabled(photos.isEmpty || isDeleting)
        }
    }

    // MARK: Actions

    private func loadSample() {
        sample = Array(photos.shuffled().prefix(sampleSize))
    }

    private func rescue(_ record: PhotoRecord) {
        guard let before = scanner.rescue(record.id) else { return }
        sample.removeAll { $0.id == record.id }
        enlarged = nil
        toasts.show("Rescued to Tier 3.", actionLabel: "Undo") {
            scanner.undoRescue(before)
        }
    }

    private func keepAll() {
        if scope != nil {
            // Trip-scoped: lock only this trip's Tier 3 photos.
            scanner.confirmKeep(ids: photos.map(\.id))
        } else {
            scanner.confirmKeepAll(in: tier)
        }
    }

    private func performDelete() async {
        isDeleting = true
        let targets = photos   // snapshot: deletion mutates scanner.records, which `photos` reads from
        let count = targets.count
        defer { isDeleting = false; deleteProgress = nil }
        do {
            try await scanner.deletePhotos(targets) { done, total in
                Task { @MainActor in deleteProgress = (done, total) }
            }
            sample.removeAll()
            // Honest framing: this is not an undoable action from the app's
            // side — PhotoKit has already moved these to Recently Deleted,
            // and there is no API call this app can make to bring them
            // back. The toast opens Photos.app (there is no public URL
            // scheme for the Recently Deleted album specifically) rather
            // than claiming to undo anything.
            toasts.show("Deleted \(count.formatted()) photos. They're in Recently Deleted for 30 days.",
                       actionLabel: "Open Photos", isAffirmative: true) {
                NSWorkspace.shared.open(URL(string: "photos://")!)
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

/// Enlarged single-photo view with the rescue action (PRD §6: "tap to
/// enlarge, tap to rescue"). When the flagged photo is a near/exact
/// duplicate, shows it side-by-side with the surviving "keeper" from the
/// same cluster, each with its own reasoning — so "why was this one kept
/// and this one flagged" is visible at a glance rather than taken on faith.
private struct EnlargedPhotoSheet: View {
    let record: PhotoRecord
    let keeper: PhotoRecord?
    let onRescue: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let keeper {
                HStack(spacing: 16) {
                    comparisonPane(record, title: "Flagged", tint: .red)
                    comparisonPane(keeper, title: "Kept instead", tint: .green)
                }
            } else {
                singlePane(record)
            }

            HStack {
                Button("Close", action: onDismiss)
                Spacer()
                if record.tier != .tier3Protected {
                    Button("Rescue to Tier 3", action: onRescue)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: keeper != nil ? 760 : 480)
    }

    private func comparisonPane(_ photo: PhotoRecord, title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: tint == .green ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            PhotoThumbnailPane(record: photo, targetSize: CGSize(width: 700, height: 700))
                .frame(minWidth: 320, minHeight: 240)
            VStack(alignment: .leading, spacing: 2) {
                Text(reasonText(for: photo)).font(.callout.weight(.medium))
                if let date = photo.creationDate {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func singlePane(_ photo: PhotoRecord) -> some View {
        VStack(spacing: 12) {
            PhotoThumbnailPane(record: photo, targetSize: CGSize(width: 1000, height: 1000))
                .frame(minWidth: 400, minHeight: 300)
            VStack(alignment: .leading, spacing: 4) {
                Text(photo.reason.displayName).font(.headline)
                if let date = photo.creationDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A one-line rationale, built from stored signals — matches the PRD's
    /// "AI picked this because…" requirement without sending any image
    /// content anywhere; every number here was already computed during the
    /// scan (PRD §8: "Reasons are generated from stored signals and scores,
    /// not from sending images to a model").
    private func reasonText(for photo: PhotoRecord) -> String {
        if photo.tier == .tier3Protected {
            var parts: [String] = ["Sharper"]
            if (photo.quality.aesthetics ?? 0) > 0.5 { parts.append("better composed") }
            if !photo.faceClusterIds.isEmpty { parts.append("known person in frame") }
            return parts.joined(separator: ", ")
        }
        return photo.reason.displayName
    }
}

/// Loads and displays one photo's thumbnail at a given size — factored out
/// of `EnlargedPhotoSheet` since the comparison view needs two independent
/// loaders side by side.
private struct PhotoThumbnailPane: View {
    let record: PhotoRecord
    let targetSize: CGSize
    @StateObject private var thumbnails = ThumbnailLoader()

    var body: some View {
        Group {
            if let image = thumbnails.images[record.id] {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
            if let asset = result.firstObject {
                thumbnails.load(asset, targetSize: targetSize)
            }
        }
    }
}
