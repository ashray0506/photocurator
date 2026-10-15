import SwiftUI
import Photos

/// The Memories browser: a full-width destination, not a nested sidebar
/// list. Replaces an earlier design where all ~50 trips were expandable
/// rows in the sidebar — which made the sidebar a wall of text, buried
/// every trip's contents behind a hard-to-hit disclosure triangle, and
/// made "which trip was that?" a reading exercise rather than a visual one.
///
/// Modelled on how Apple Photos actually structures this: a few featured
/// memories as large cards up top, then everything else grouped by year
/// with headers, each card led by a real cover photo rather than a label.
struct MemoriesView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFindingTrips = false
    @State private var isRefreshingNames = false
    @State private var renamingTrip: Trip?
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    /// Biggest trips by photo count — "featured" in the sense Apple Photos
    /// uses it (the ones most worth revisiting), not most recent, since a
    /// 3-photo recent trip makes a poor hero card.
    private var featured: [Trip] {
        scanner.trips
            .sorted { $0.photoIds.count > $1.photoIds.count }
            .prefix(3)
            .map { $0 }
    }

    private var byYear: [(year: Int, trips: [Trip])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: scanner.trips) {
            calendar.component(.year, from: $0.startDay)
        }
        return grouped.keys.sorted(by: >).map { year in
            (year, grouped[year]!.sorted { $0.startDay > $1.startDay })
        }
    }

    var body: some View {
        ScrollView {
            if scanner.trips.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 34) {
                    featuredSection
                    ForEach(byYear, id: \.year) { entry in
                        yearSection(entry.year, entry.trips)
                    }
                }
                .padding(28)
            }
        }
        .navigationTitle("Memories")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await refreshAllTripNames() }
                } label: {
                    if isRefreshingNames {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh Names", systemImage: "textformat")
                    }
                }
                .disabled(scanner.trips.isEmpty || isRefreshingNames)
                .help("Rename every memory using country-aware naming")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await findTrips() }
                } label: {
                    if isFindingTrips {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Find Memories", systemImage: "sparkle.magnifyingglass")
                    }
                }
                .disabled(scanner.records.isEmpty || isFindingTrips)
            }
        }
        .sheet(item: $renamingTrip) { trip in
            RenameTripSheet(trip: trip) { newName in
                scanner.renameTrip(id: trip.id, to: newName)
                renamingTrip = nil
            }
        }
    }

    /// Right-click actions on a card. "Delete Memory" removes the memory
    /// itself (the grouping), never the photos in it — the wording says so
    /// explicitly, since "delete" next to a wall of photos could easily be
    /// read as deleting them. Deleting actual photos stays inside a
    /// memory's own Junk / Redundant / Extra Photos screens, each behind
    /// its own confirmation.
    @ViewBuilder
    private func cardMenu(_ trip: Trip) -> some View {
        Button("Rename…") { renamingTrip = trip }
        Button("Refresh Name") { Task { await scanner.refreshTripName(id: trip.id) } }
        Divider()
        Button("Delete Memory (Keeps Photos)", role: .destructive) {
            scanner.deleteTrip(id: trip.id)
        }
    }

    private func findTrips() async {
        isFindingTrips = true
        defer { isFindingTrips = false }
        await scanner.autoSaveDetectedTrips()
    }

    private func refreshAllTripNames() async {
        isRefreshingNames = true
        defer { isRefreshingNames = false }
        for trip in scanner.trips {
            await scanner.refreshTripName(id: trip.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text("No memories yet")
                .font(Theme.titleFont(20))
            Text("Scan your library and PhotoCurator will find your trips.")
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: Featured

    @ViewBuilder
    private var featuredSection: some View {
        if !featured.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Featured")
                    .font(Theme.titleFont(22))
                    .foregroundStyle(colors.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(featured) { trip in
                            MemoryCard(trip: trip, size: .hero)
                                .contextMenu { cardMenu(trip) }
                        }
                    }
                    .padding(.bottom, 6)   // room for the cards' shadow
                }
            }
        }
    }

    // MARK: Per-year grid

    private func yearSection(_ year: Int, _ trips: [Trip]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(year))
                .font(Theme.titleFont(22))
                .foregroundStyle(colors.ink)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(trips) { trip in
                    MemoryCard(trip: trip, size: .standard)
                        .contextMenu { cardMenu(trip) }
                }
            }
        }
    }
}

/// One memory card: cover photo filling the card, name and date range
/// overlaid at the bottom over a gradient so text stays readable on any
/// photo, and a subtle lift on hover.
struct MemoryCard: View {
    enum Size {
        case hero, standard

        var dimensions: CGSize {
            switch self {
            case .hero: return CGSize(width: 420, height: 260)
            case .standard: return CGSize(width: 260, height: 190)
            }
        }
    }

    let trip: Trip
    var size: Size = .standard

    @EnvironmentObject private var scanner: LibraryScanner
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var thumbnails = ThumbnailLoader()
    @State private var isHovering = false

    private var colors: ThemeColors { ThemeColors(colorScheme) }

    var body: some View {
        NavigationLink(value: SidebarSelection.tripDashboard(tripId: trip.id)) {
            ZStack(alignment: .bottomLeading) {
                cover
                gradientScrim
                caption
            }
            .frame(width: size.dimensions.width, height: size.dimensions.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(colors.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovering ? 0.55 : 0.4),
                    radius: isHovering ? 16 : 10, x: 0, y: isHovering ? 8 : 5)
            .scaleEffect(isHovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.18), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .task { loadCover() }
    }

    @ViewBuilder
    private var cover: some View {
        if let record = scanner.coverPhoto(for: trip), let image = thumbnails.images[record.id] {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Not a spinner: a quiet placeholder reads better than ~50
            // simultaneous spinners while PhotoKit fills a grid in.
            Rectangle()
                .fill(colors.paperRaised)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(colors.inkMuted)
                )
        }
    }

    private var gradientScrim: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.15), .black.opacity(0.75)],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trip.name)
                .font(size == .hero ? Theme.titleFont(20) : Theme.titleFont(15))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(dateRange)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: trip.startDay)
        if Calendar.current.isDate(trip.startDay, inSameDayAs: trip.endDay) {
            return "\(start) · \(trip.photoIds.count.formatted()) photos"
        }
        let end = formatter.string(from: trip.endDay)
        return "\(start) – \(end) · \(trip.photoIds.count.formatted()) photos"
    }

    private func loadCover() {
        guard let record = scanner.coverPhoto(for: trip) else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
        guard let asset = result.firstObject else { return }
        thumbnails.load(asset, targetSize: CGSize(width: size.dimensions.width * 2,
                                                  height: size.dimensions.height * 2))
    }
}
