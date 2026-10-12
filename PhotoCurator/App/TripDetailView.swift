import SwiftUI
import Photos

/// One trip, grouped by day with place-segment names (PRD §10.2/§10.3) and
/// each day's book selection (PRD §10.4: best 3-6 photos, swappable), with
/// PDF export (a simplified PRD §10.6/§10.9: no AI captions or route map
/// yet — see PhotoBookExporter for what's deferred and why).
struct TripDetailView: View {
    let trip: Trip
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var thumbnails = ThumbnailLoader()
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var swapRequest: SwapRequest?

    private var photos: [PhotoRecord] { scanner.photos(in: trip) }

    private var days: [(day: Date, photos: [PhotoRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: photos) { $0.dayStart(calendar: calendar) ?? trip.startDay }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ForEach(days, id: \.day) { entry in
                    daySection(entry.day, entry.photos)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(trip.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportPDF()
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Export PDF", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || photos.isEmpty)
            }
        }
        .alert("Export failed", isPresented: .constant(exportError != nil), actions: {
            Button("OK") { exportError = nil }
        }, message: { Text(exportError ?? "") })
        .sheet(item: $swapRequest) { request in
            SwapCandidateSheet(request: request) { incoming in
                scanner.swapPhoto(request.outgoing.id, for: incoming.id, day: request.day, in: trip)
                toasts.show("Swapped photo pick for \(request.day.formatted(.dateTime.month().day())).")
                swapRequest = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(days.count) days · \(photos.count.formatted()) photos")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func daySection(_ day: Date, _ dayPhotos: [PhotoRecord]) -> some View {
        let segments = trip.segments(for: day)
        let placeNames = segments.compactMap(\.placeName)
        let chosen = scanner.selectedPhotos(for: day, in: trip, dayPhotos: dayPhotos)
        let chosenIds = Set(chosen.map(\.id))
        let alternates = dayPhotos.filter { !chosenIds.contains($0.id) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(day, format: .dateTime.weekday(.wide).month().day())
                    .font(.headline)
                if !placeNames.isEmpty {
                    Text("· \(placeNames.joined(separator: " · "))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(chosen.count.formatted()) in book")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DayDecorationBar(day: day, trip: trip)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(chosen) { record in
                    thumbnailCell(record, isChosen: true, day: day, alternates: alternates)
                }
            }

            if !alternates.isEmpty {
                DisclosureGroup("\(alternates.count.formatted()) more from this day") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 6)], spacing: 6) {
                        ForEach(alternates) { record in
                            thumbnailCell(record, isChosen: false, day: day, alternates: chosen, size: 90)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
    }

    private func thumbnailCell(_ record: PhotoRecord, isChosen: Bool, day: Date,
                               alternates: [PhotoRecord], size: CGFloat = 140) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = thumbnails.images[record.id] {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
                guard let asset = result.firstObject else { return }
                thumbnails.load(asset, targetSize: CGSize(width: size * 1.3, height: size * 1.3))
            }

            if isChosen, !alternates.isEmpty {
                Button {
                    swapRequest = SwapRequest(outgoing: record, day: day, candidates: alternates)
                } label: {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
    }

    private func exportPDF() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let selectedDays = days.map { entry in
                    (day: entry.day, photos: scanner.selectedPhotos(for: entry.day, in: trip, dayPhotos: entry.photos))
                }
                let url = try await PhotoBookExporter().export(trip: trip, days: selectedDays)
                isExporting = false
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// What the swap sheet needs: which photo is being replaced, which day it
/// belongs to (selection is stored per day), and the candidates to choose
/// from (the day's other photos).
private struct SwapRequest: Identifiable {
    let outgoing: PhotoRecord
    let day: Date
    let candidates: [PhotoRecord]
    var id: String { outgoing.id }
}

/// PRD §10.8: "swap any chosen photo for another from the same cluster" —
/// broadened here to the whole day, since the book selection now spans
/// a full day rather than one cluster.
private struct SwapCandidateSheet: View {
    let request: SwapRequest
    let onPick: (PhotoRecord) -> Void
    @StateObject private var thumbnails = ThumbnailLoader()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Swap this photo").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            Text("Choose a replacement from this day's other photos.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 8)], spacing: 8) {
                    ForEach(request.candidates) { candidate in
                        Group {
                            if let image = thumbnails.images[candidate.id] {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(.quaternary)
                            }
                        }
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture {
                            onPick(candidate)
                            dismiss()
                        }
                        .onAppear {
                            let result = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: nil)
                            guard let asset = result.firstObject else { return }
                            thumbnails.load(asset, targetSize: CGSize(width: 160, height: 160))
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
