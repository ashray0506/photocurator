import SwiftUI
import Photos

/// The combined review + book-draft sitting for a just-finished trip.
///
/// Unlike the full-library flow (dashboard → tier review → separate Trips
/// tab), this collapses junk review and the book draft into one screen:
/// the volume here is a few hundred photos, not tens of thousands, so the
/// "see the draft right after clearing junk" moment matters more than
/// keeping every step a separate screen.
struct TripWrapUpView: View {
    let candidate: TripDetector.Candidate
    let onDone: () -> Void

    @EnvironmentObject private var scanner: LibraryScanner
    @StateObject private var thumbnails = ThumbnailLoader()
    @State private var tripName: String = ""
    @State private var isResolvingPlaces = true
    @State private var resolvedSegments: [String: [TripPlaceSegment]] = [:]
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var didSave = false
    @Environment(\.dismiss) private var dismiss

    /// This trip's own records, from the already-scanned library — a Trip
    /// Wrap-Up never re-analyses pixels; the photos were tiered by the scan
    /// that ran on launch, same as any other candidate.
    private var tripRecords: [PhotoRecord] {
        let ids = Set(candidate.photoIds)
        return scanner.records.filter { ids.contains($0.id) }
    }

    private var junkPhotos: [PhotoRecord] { tripRecords.filter { $0.tier != .tier3Protected } }
    private var keepPhotos: [PhotoRecord] { tripRecords.filter { $0.tier == .tier3Protected } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if !junkPhotos.isEmpty {
                        junkSection
                    }
                    bookPreviewSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Trip Wrap-Up")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss(); onDone() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save Trip") { Task { await saveTrip() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(tripName.trimmingCharacters(in: .whitespaces).isEmpty || didSave)
                }
            }
            .confirmationDialog(
                "Clear \(junkPhotos.count.formatted()) extra photos from this trip?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear \(junkPhotos.count.formatted()) Photos", role: .destructive) {
                    Task { await deleteJunk() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They stay in Recently Deleted for 30 days.")
            }
            .task {
                tripName = Trip.suggestedName(startDay: candidate.startDay, endDay: candidate.endDay)
                resolvedSegments = await scanner.resolvePlaceNames(for: candidate.segmentsByDay)
                isResolvingPlaces = false
                let placeNames = resolvedSegments.values.flatMap { $0 }.compactMap(\.placeName)
                if !placeNames.isEmpty {
                    var seen = Set<String>()
                    let distinct = placeNames.filter { seen.insert($0).inserted }
                    tripName = Trip.suggestedName(startDay: candidate.startDay, endDay: candidate.endDay,
                                                  placeNames: distinct)
                }
            }
        }
        .frame(width: 720, height: 680)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Welcome back — here's your trip", systemImage: "airplane.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.blue)

            TextField("Trip name", text: $tripName)
                .textFieldStyle(.roundedBorder)
                .font(.title3.weight(.semibold))

            if isResolvingPlaces {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking up places…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("\(candidate.dayCount) days · \(tripRecords.count.formatted()) photos")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Junk clearing

    private var junkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clear the extras")
                    .font(.headline)
                Spacer()
                Text("\(junkPhotos.count.formatted()) of \(tripRecords.count.formatted()) photos")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Duplicates, blurry shots and screenshots from this trip — your book only needs the keepers below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 110), spacing: 6)], spacing: 6) {
                ForEach(junkPhotos.prefix(24)) { record in
                    thumbnailCell(record, size: 90)
                }
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Text("Clear \(junkPhotos.count.formatted()) Extra Photos")
            }
            .disabled(isDeleting)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Book preview

    private var bookPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your book draft")
                .font(.headline)
            Text("\(keepPhotos.count.formatted()) photos make the cut. Save the trip to open the full editor and export a PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 8)], spacing: 8) {
                ForEach(keepPhotos.prefix(12)) { record in
                    thumbnailCell(record, size: 100)
                }
            }
        }
    }

    private func thumbnailCell(_ record: PhotoRecord, size: CGFloat) -> some View {
        Group {
            if let image = thumbnails.images[record.id] {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
            guard let asset = result.firstObject else { return }
            thumbnails.load(asset, targetSize: CGSize(width: size * 1.5, height: size * 1.5))
        }
    }

    // MARK: Actions

    private func deleteJunk() async {
        isDeleting = true
        defer { isDeleting = false }
        // Routed through the scanner (not the deletion service directly) so
        // `scanner.records` drops these immediately — otherwise `junkPhotos`
        // and `keepPhotos` above would still show the deleted photos for
        // the rest of this sitting.
        try? await scanner.deletePhotos(junkPhotos)
    }

    private func saveTrip() async {
        scanner.saveTrip(name: tripName, candidate: candidate, placeSegmentsByDay: resolvedSegments)
        didSave = true
        dismiss()
        onDone()
    }
}
