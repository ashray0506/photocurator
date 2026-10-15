import SwiftUI
import MapKit
import CoreLocation

/// The cross-trip overview: every memory's route plotted on one map, a
/// "passport stamp" card per distinct city/country visited, and a total
/// distance travelled — requested directly as a way to see everything at
/// once, not just one trip's journey map.
///
/// Distance is a straight-line sum between consecutive day-stops within
/// each trip (`CLLocation.distance(from:)`, which is already great-circle/
/// haversine) — an honest lower bound on actual travel distance, not a
/// routed driving/flying distance, since this app has no routing data and
/// never calls out to one (on-device only, no network dependency for a
/// number that's meant to be a fun fact, not a navigation figure).
struct WorldMapView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isRefreshing = false
    @State private var hasAPIKey = false
    @State private var isGeneratingCaptions = false
    @State private var captionRefreshToken = 0

    private var allStops: [(trip: Trip, stop: Trip.RouteStop)] {
        scanner.trips.flatMap { trip in trip.dailyRoute.map { (trip, $0) } }
    }

    /// Distinct cities (falling back to a trip's country when a stop's
    /// own city is unknown), each counted once no matter how many trips
    /// or days visited it — one stamp per place, not per visit. Paired
    /// with a country when the stop has one, for the AI caption prompt.
    private var stampPlaces: [(place: String, country: String?)] {
        var seen = Set<String>()
        var ordered: [(String, String?)] = []
        for (trip, stop) in allStops {
            let label = stop.placeName ?? trip.name
            guard seen.insert(label).inserted else { continue }
            ordered.append((label, stop.country))
        }
        return ordered.sorted { $0.0 < $1.0 }
    }

    private var totalMiles: Double {
        var meters: Double = 0
        for trip in scanner.trips {
            let ordered = trip.dailyRoute
            guard ordered.count >= 2 else { continue }
            for i in 1..<ordered.count {
                let a = CLLocation(latitude: ordered[i - 1].coordinate.latitude, longitude: ordered[i - 1].coordinate.longitude)
                let b = CLLocation(latitude: ordered[i].coordinate.latitude, longitude: ordered[i].coordinate.longitude)
                meters += a.distance(from: b)
            }
        }
        return meters / 1609.34
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                statsRow
                if !allStops.isEmpty {
                    mapSection
                }
                stampsSection
            }
            .padding(28)
        }
        .navigationTitle("World Map")
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack(spacing: 14) {
            statCard(value: stampPlaces.count.formatted(), label: "Places Visited", icon: "mappin.and.ellipse")
            statCard(value: scanner.trips.count.formatted(), label: "Trips", icon: "photo.stack")
            statCard(value: totalMiles > 0 ? "\(Int(totalMiles).formatted())" : "—", label: "Miles Travelled", icon: "airplane")
        }
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(Theme.titleFont(26))
                .foregroundStyle(colors.ink)
            Text(label)
                .font(.caption)
                .foregroundStyle(colors.inkMuted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(colors, cornerRadius: 14)
    }

    // MARK: Map

    private var mapSection: some View {
        Map(position: $cameraPosition) {
            ForEach(Array(allStops.enumerated()), id: \.offset) { _, entry in
                Annotation(entry.stop.placeName ?? entry.trip.name, coordinate: entry.stop.coordinate) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted))
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.hairline, lineWidth: 1))
    }

    // MARK: Stamps

    private var stampsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Passport Stamps")
                    .font(Theme.titleFont(20))
                    .foregroundStyle(colors.ink)
                Spacer()
                // Opt-in, one button for every stamp at once — not a
                // request per card on every render, which would be
                // surprising and costly. Only shown once there's at
                // least one un-captioned stamp left to generate.
                if hasAPIKey && !stampPlaces.isEmpty && uncaptionedCount > 0 {
                    Button {
                        Task { await generateAllCaptions() }
                    } label: {
                        if isGeneratingCaptions {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Generate AI Captions (\(uncaptionedCount))", systemImage: "sparkles")
                        }
                    }
                    .disabled(isGeneratingCaptions)
                    .font(.caption)
                }
            }

            if stampPlaces.isEmpty {
                emptyStampsState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)], spacing: 14) {
                    ForEach(stampPlaces, id: \.place) { entry in
                        StampCard(label: entry.place, caption: AICaptionStore.caption(for: entry.place))
                    }
                }
                // `.id` on the whole grid, keyed to the refresh token:
                // `AICaptionStore.caption(for:)` reads `UserDefaults`
                // directly rather than published `@State`, so SwiftUI has
                // no other signal that a card's caption changed after a
                // background generation call completes — forcing the
                // grid's identity to change is what makes it re-read.
                .id(captionRefreshToken)
            }
        }
        .task { hasAPIKey = APIKeyStore.load() != nil }
    }

    private var uncaptionedCount: Int {
        stampPlaces.filter { AICaptionStore.caption(for: $0.place) == nil }.count
    }

    private func generateAllCaptions() async {
        isGeneratingCaptions = true
        defer { isGeneratingCaptions = false }
        for entry in stampPlaces where AICaptionStore.caption(for: entry.place) == nil {
            if let caption = try? await AIStampGenerator().suggestCaption(place: entry.place, country: entry.country) {
                AICaptionStore.save(caption, for: entry.place)
                captionRefreshToken += 1   // force the grid to re-read the cache
            }
        }
    }

    /// Trips saved before place coordinates were persisted (added
    /// alongside this map/stamps feature) have no `latitude`/`longitude`
    /// on their segments at all — reported directly as "nothing in
    /// passport stamps," confirmed by checking the live cache (0 of 1203
    /// segments had coordinates). "Refresh Name" is the only thing that
    /// re-resolves place data and backfills them; surfacing that fix
    /// directly here, rather than only in a one-time chat message, is
    /// what was actually missing — not a map/stamps logic bug.
    @ViewBuilder
    private var emptyStampsState: some View {
        if scanner.trips.isEmpty {
            Text("Scan your library and find memories to start collecting stamps.")
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your \(scanner.trips.count.formatted()) memories were saved before place coordinates were tracked, so there's nothing to show on the map or in stamps yet.")
                    .font(.callout)
                    .foregroundStyle(colors.inkMuted)
                Button {
                    Task { await refreshAllCoordinates() }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh All Names & Locations", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
    }

    private func refreshAllCoordinates() async {
        isRefreshing = true
        defer { isRefreshing = false }
        for trip in scanner.trips {
            await scanner.refreshTripName(id: trip.id)
        }
    }
}

/// A single "passport stamp" — a circular, rotated badge like an ink stamp
/// pressed into a passport page, rather than a plain list row. Rotation is
/// derived from the name itself (not random) so it's stable across
/// re-renders instead of jittering every time the view redraws.
private struct StampCard: View {
    let label: String
    var caption: String?
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    private var rotation: Double {
        let seed = label.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(seed % 13) - 6   // -6...6 degrees
    }

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .stroke(Theme.accent, lineWidth: 2)
                .overlay(
                    Circle()
                        .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
                        .padding(5)
                )
                .overlay(
                    Text(initials)
                        .font(Theme.titleFont(22))
                        .foregroundStyle(Theme.accent)
                )
                .frame(width: 92, height: 92)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(colors.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let caption {
                Text(caption)
                    .font(.caption2.italic())
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .rotationEffect(.degrees(rotation))
        .padding(10)
    }

    private var initials: String {
        let words = label.split(separator: ",").first?.split(separator: " ") ?? []
        let letters = words.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}
