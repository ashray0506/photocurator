import SwiftUI
import Photos

/// One trip, grouped by day, with PDF export (a simplified PRD §10.6/§10.9:
/// one section per day with a photo grid; no AI captions or route map yet —
/// see PhotoBookExporter for what's deferred and why).
struct TripDetailView: View {
    let trip: Trip
    @EnvironmentObject private var scanner: LibraryScanner
    @StateObject private var thumbnails = ThumbnailLoader()
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showingSavePanel = false

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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(days.count) days · \(photos.count.formatted()) photos")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func daySection(_ day: Date, _ dayPhotos: [PhotoRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day, format: .dateTime.weekday(.wide).month().day())
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(dayPhotos) { record in
                    thumbnailCell(record)
                }
            }
        }
    }

    private func thumbnailCell(_ record: PhotoRecord) -> some View {
        Group {
            if let image = thumbnails.images[record.id] {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
            guard let asset = result.firstObject else { return }
            thumbnails.load(asset, targetSize: CGSize(width: 180, height: 180))
        }
    }

    private func exportPDF() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await PhotoBookExporter().export(trip: trip, days: days)
                isExporting = false
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}
