import SwiftUI
import Photos

/// One trip, as a paginated album — a cover page (the hero card), then one
/// page per day, each with its place-segment names (PRD §10.2/§10.3) and
/// book selection (PRD §10.4: best 3-6 photos, swappable). Prev/Next flips
/// between pages with a page-curl transition and a paper-rustle sound,
/// "the feel of turning pages in a paper album" — requested directly,
/// replacing an earlier continuous-scroll layout that showed every day at
/// once. PDF export (a simplified PRD §10.6/§10.9: no AI captions or route
/// map yet — see PhotoBookExporter for what's deferred and why) still
/// exports every day, independent of which page is currently showing.
struct TripDetailView: View {
    let trip: Trip
    /// When set (from the sidebar's per-day rows), opens straight to that
    /// day's page instead of the cover.
    var scrollToDayKey: String?
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var thumbnails = ThumbnailLoader()
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var swapRequest: SwapRequest?
    @State private var showingJourneyMap = false
    /// -1 is the cover page (the hero card); 0..<days.count are day pages.
    @State private var pageIndex = -1
    @State private var flipForward = true
    @StateObject private var curl = PageCurlController()
    @State private var hasAPIKey = false
    @State private var isSuggestingName = false

    private var photos: [PhotoRecord] { scanner.photos(in: trip) }

    private var days: [(day: Date, photos: [PhotoRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: photos) { $0.dayStart(calendar: calendar) ?? trip.startDay }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                PageCurlView(controller: curl)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            pageControls
        }
        .task(id: pageIndex) {
            // `.task(id:)`, not `.onChange`: this needs to fire once on
            // first appearance too (to seed `curl.current` with the cover
            // page) in addition to every later page change, which
            // `onChange` alone would miss. `PageCurlController.transition`
            // itself detects "first call" and skips the sound/animation
            // for it, so this doesn't need its own first-appearance guard.
            curl.transition(to: pageContentView, forward: flipForward) {
                PageTurnSound.play()
            }
        }
        .task(id: scrollToDayKey) {
            guard let scrollToDayKey,
                  let index = days.firstIndex(where: { Trip.dayKey($0.day) == scrollToDayKey }) else { return }
            pageIndex = index
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
            // The per-trip cleanup screens used to be sidebar rows under
            // each trip; with the sidebar reduced to two destinations,
            // this menu is how they're reached — and the answer to "how
            // do I delete?", which was genuinely hard to find before.
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    NavigationLink("Junk (\(count(of: .tier1)))",
                                   value: SidebarSelection.tripTier(tripId: trip.id, tier: .tier1))
                    NavigationLink("Redundant (\(count(of: .tier2)))",
                                   value: SidebarSelection.tripTier(tripId: trip.id, tier: .tier2))
                    NavigationLink("Keeps (\(count(of: .tier3Protected)))",
                                   value: SidebarSelection.tripTier(tripId: trip.id, tier: .tier3Protected))
                    Divider()
                    NavigationLink("Extra Photos (\(scanner.unselectedExtras(in: trip).count))",
                                   value: SidebarSelection.tripExtras(tripId: trip.id))
                } label: {
                    Label("Clean Up", systemImage: "trash")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingJourneyMap = true
                } label: {
                    Label("Journey Map", systemImage: "map")
                }
            }
        }
        .sheet(isPresented: $showingJourneyMap) {
            JourneyMapView(trip: trip)
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

    private func count(of tier: Tier) -> Int {
        photos.filter { $0.tier == tier }.count
    }

    // MARK: Pages

    @ViewBuilder
    private var pageContentView: some View {
        if pageIndex < 0 {
            TripHeroCard(trip: trip, days: days, photos: photos,
                        onOpenBook: { goToPage(0) },
                        onSuggestName: hasAPIKey ? { await suggestName() } : nil,
                        isSuggestingName: isSuggestingName)
                .task { hasAPIKey = APIKeyStore.load() != nil }
        } else if pageIndex < days.count {
            let entry = days[pageIndex]
            daySection(entry.day, entry.photos)
        }
    }

    /// Same call `RenameTripSheet`'s "Suggest with AI" makes, surfaced
    /// directly on the cover page instead of only behind a right-click
    /// rename sheet — reported directly as hard to find ("cant we find a
    /// name using ai"), the same discoverability problem the API key
    /// field itself had.
    private func suggestName() async {
        isSuggestingName = true
        defer { isSuggestingName = false }
        let stops = LibraryScanner.namingStops(from: trip.placeSegmentsByDay)
        let country = stops.first?.country
        let places = stops.map(\.name)
        guard let suggestion = try? await AITripNamer().suggestName(
            places: places, country: country, startDay: trip.startDay, endDay: trip.endDay) else {
            toasts.show("Couldn't reach the AI naming service.")
            return
        }
        scanner.renameTrip(id: trip.id, to: suggestion)
    }

    /// A trip spanning weeks or months can have dozens of day-pages —
    /// reported directly: "many trips have over thousands of photos,"
    /// clicking Next once per day doesn't scale even though pagination is
    /// already per-day, not per-photo. The day picker below is the fix:
    /// jump straight to any day instead of stepping through every one.
    private var pageControls: some View {
        HStack {
            Button {
                goToPage(pageIndex - 1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(pageIndex <= -1)

            Spacer()

            dayPicker

            Spacer()

            Button {
                goToPage(pageIndex + 1)
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
            }
            .disabled(pageIndex >= days.count - 1)
        }
        .buttonStyle(.bordered)
        .padding(14)
        .background(.ultraThinMaterial)
    }

    /// Jump directly to any page — the cover, or any day by its date —
    /// instead of only being able to step one page at a time.
    private var dayPicker: some View {
        Menu {
            Button("Cover") { goToPage(-1) }
            Divider()
            ForEach(Array(days.enumerated()), id: \.offset) { index, entry in
                Button(dayMenuLabel(entry.day)) { goToPage(index) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(pageLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var pageLabel: String {
        pageIndex < 0 ? "Cover" : dayMenuLabel(days[pageIndex].day)
    }

    private func dayMenuLabel(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func goToPage(_ index: Int) {
        let clamped = max(-1, min(days.count - 1, index))
        guard clamped != pageIndex else { return }
        // The sound plays from inside `PageCurlController.transition`,
        // timed to the actual curl animation it starts — not here, which
        // would fire before the `.task(id: pageIndex)` below even runs.
        flipForward = clamped > pageIndex
        pageIndex = clamped
    }

    /// A day's page, styled as a leaf in a physical album rather than a
    /// plain list section — reported directly: "not seeing the page
    /// option that feels like a noir and nostalgic photo paper album."
    /// Earlier this was an unstyled `VStack` with a system-font header;
    /// now it's a raised paper card (`themedCard`, same language as the
    /// hero card and Memories grid) with a serif date heading like a
    /// hand-labelled album page, sitting on the noir background.
    private func daySection(_ day: Date, _ dayPhotos: [PhotoRecord]) -> some View {
        let segments = trip.segments(for: day)
        let placeNames = segments.compactMap(\.placeName)
        let chosen = scanner.selectedPhotos(for: day, in: trip, dayPhotos: dayPhotos)
        let chosenIds = Set(chosen.map(\.id))
        let alternates = dayPhotos.filter { !chosenIds.contains($0.id) }

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(Theme.titleFont(24))
                    .foregroundStyle(colors.ink)
                HStack(spacing: 6) {
                    if !placeNames.isEmpty {
                        Text(placeNames.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text("\(chosen.count.formatted()) in book")
                        .font(.caption)
                        .foregroundStyle(colors.inkMuted)
                }
            }

            DayDecorationBar(day: day, trip: trip)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 10)], spacing: 10) {
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
                .foregroundStyle(colors.inkMuted)
                .tint(Theme.accent)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(colors, cornerRadius: 16)
    }

    /// A thin cream border around the photo, like a printed snapshot's own
    /// white edge, rather than a photo clipped edge-to-edge — small touch,
    /// but it's the difference between "app thumbnail" and "print in an
    /// album," which is what the nostalgic framing is going for.
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
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(5)
            .background(colors.paperRaised, in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
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
