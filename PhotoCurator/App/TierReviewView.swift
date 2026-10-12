import SwiftUI
import Photos

/// The one-button-per-tier review screen (PRD §6).
///
/// Shows a sample preview grid, a reason breakdown, and exactly one primary
/// action: "Keep all" for Tier 3 (no delete action exists for that tier —
/// there is no button in this view that can touch it), or "Delete Tier N"
/// for Tier 1/2, gated by a single confirmation sheet.
struct TierReviewView: View {
    let tier: Tier
    @EnvironmentObject private var scanner: LibraryScanner
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

    private var photos: [PhotoRecord] { scanner.photos(in: tier) }

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
                scanner.confirmKeepAll(in: tier)
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
        scanner.rescue(record.id)
        sample.removeAll { $0.id == record.id }
        enlarged = nil
    }

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false; deleteProgress = nil }
        do {
            try await scanner.deleteAll(in: tier) { done, total in
                Task { @MainActor in deleteProgress = (done, total) }
            }
            sample.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

/// Enlarged single-photo view with the rescue action (PRD §6: "tap to
/// enlarge, tap to rescue").
private struct EnlargedPhotoSheet: View {
    let record: PhotoRecord
    let onRescue: () -> Void
    let onDismiss: () -> Void
    @StateObject private var thumbnails = ThumbnailLoader()

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let image = thumbnails.images[record.id] {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(minWidth: 400, minHeight: 300)
            .task {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
                if let asset = result.firstObject {
                    thumbnails.load(asset, targetSize: CGSize(width: 1000, height: 1000))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.reason.displayName).font(.headline)
                if let date = record.creationDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .frame(width: 480)
    }
}
