import SwiftUI
import Photos

/// A Tinder-style one-at-a-time review for Tier 2 (likely unwanted):
/// swipe right to keep (rescues the photo to Tier 3), left to mark for
/// deletion. Requested directly as an alternative to the grid-based
/// `TierReviewView` for someone who wants a faster, more deliberate
/// decision per photo rather than scanning a whole grid at once.
///
/// Deliberately not "delete on every left swipe": discards are collected
/// into `markedForDeletion` and only actually removed from the library
/// once, at the end, behind the same confirmation + Recently Deleted
/// framing every other delete path in this app uses — PhotoKit's own
/// system confirmation sheet firing on every single swipe would make the
/// gesture unusable, and PRD §9's "one clear confirmation" principle
/// applies here just as much as to a whole-tier delete.
struct SwipeReviewView: View {
    var scope: Trip?
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var thumbnails = ThumbnailLoader()
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    @State private var queue: [PhotoRecord] = []
    @State private var markedForDeletion: [PhotoRecord] = []
    @State private var keptCount = 0
    @State private var dragOffset: CGSize = .zero
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteProgress: (done: Int, total: Int)?
    @State private var deleteError: String?

    private let thumbSize = CGSize(width: 900, height: 900)

    private var photos: [PhotoRecord] {
        guard let scope else { return scanner.photos(in: .tier2) }
        let tripIds = Set(scope.photoIds)
        return scanner.photos(in: .tier2).filter { tripIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 20) {
            progressHeader

            if let current = queue.last {
                card(current)
                    .id(current.id)
            } else {
                doneState
            }

            controls
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Swipe Review")
        .task { if queue.isEmpty { queue = photos.reversed() } }
        .confirmationDialog(
            "Delete \(markedForDeletion.count.formatted()) photos?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(markedForDeletion.count.formatted()) Photos", role: .destructive) {
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

    // MARK: Header

    private var progressHeader: some View {
        let total = keptCount + markedForDeletion.count + queue.count
        return VStack(spacing: 4) {
            Text("\(keptCount + markedForDeletion.count) of \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(colors.inkMuted)
            HStack(spacing: 16) {
                Label("\(keptCount.formatted()) kept", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(colors.inkMuted)
                Label("\(markedForDeletion.count.formatted()) marked", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(colors.inkMuted)
            }
        }
    }

    // MARK: Card

    private func card(_ record: PhotoRecord) -> some View {
        ZStack {
            Group {
                if let image = thumbnails.images[record.id] {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(maxWidth: 520, maxHeight: 520)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onAppear { requestThumbnail(record) }
            .overlay(alignment: .topLeading) {
                if dragOffset.width > 20 {
                    stampLabel("KEEP", tint: Theme.olive, opacity: min(1, dragOffset.width / 120))
                }
            }
            .overlay(alignment: .topTrailing) {
                if dragOffset.width < -20 {
                    stampLabel("DISCARD", tint: Theme.rust, opacity: min(1, -dragOffset.width / 120))
                }
            }
        }
        .themedCard(colors, cornerRadius: 14)
        .offset(x: dragOffset.width, y: dragOffset.height * 0.2)
        .rotationEffect(.degrees(Double(dragOffset.width / 20)))
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in handleDragEnd(value.translation, record: record) }
        )
        .animation(.interactiveSpring(), value: dragOffset)
    }

    private func stampLabel(_ text: String, tint: Color, opacity: Double) -> some View {
        Text(text)
            .font(.title2.weight(.heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint, lineWidth: 3))
            .rotationEffect(.degrees(-12))
            .opacity(opacity)
            .padding(16)
    }

    private var doneState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.olive)
            Text("All reviewed")
                .font(Theme.titleFont(20))
            Text("\(keptCount.formatted()) kept, \(markedForDeletion.count.formatted()) marked for deletion.")
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 24) {
            Button {
                if let current = queue.last { decide(current, keep: false) }
            } label: {
                Label("Discard", systemImage: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 140)
            }
            .buttonStyle(.bordered)
            .tint(Theme.rust)
            .disabled(queue.isEmpty)

            Button {
                if let current = queue.last { decide(current, keep: true) }
            } label: {
                Label("Keep", systemImage: "checkmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 140)
            }
            .buttonStyle(.bordered)
            .tint(Theme.olive)
            .disabled(queue.isEmpty)

            if !markedForDeletion.isEmpty {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete \(markedForDeletion.count.formatted())", systemImage: "trash")
                }
                .disabled(isDeleting)
            }

            if let progress = deleteProgress {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(width: 120)
            }
        }
    }

    // MARK: Actions

    private func handleDragEnd(_ translation: CGSize, record: PhotoRecord) {
        let threshold: CGFloat = 120
        if translation.width > threshold {
            decide(record, keep: true)
        } else if translation.width < -threshold {
            decide(record, keep: false)
        } else {
            dragOffset = .zero
        }
    }

    private func decide(_ record: PhotoRecord, keep: Bool) {
        if keep {
            scanner.rescue(record.id)
            keptCount += 1
        } else {
            markedForDeletion.append(record)
        }
        queue.removeLast()
        dragOffset = .zero
        if let next = queue.last {
            requestThumbnail(next)
        }
    }

    private func requestThumbnail(_ record: PhotoRecord) {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
        guard let asset = result.firstObject else { return }
        thumbnails.load(asset, targetSize: thumbSize)
    }

    private func performDelete() async {
        isDeleting = true
        let targets = markedForDeletion
        defer { isDeleting = false; deleteProgress = nil }
        do {
            try await scanner.deletePhotos(targets) { done, total in
                Task { @MainActor in deleteProgress = (done, total) }
            }
            markedForDeletion.removeAll()
            toasts.show("Deleted \(targets.count.formatted()) photos. They're in Recently Deleted for 30 days.",
                       actionLabel: "Open Photos", isAffirmative: true) {
                NSWorkspace.shared.open(URL(string: "photos://")!)
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
