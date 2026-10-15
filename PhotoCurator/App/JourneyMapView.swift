import SwiftUI
import MapKit

/// A full-screen "replay this trip" map: the trip's route, one stop per
/// day, with the line and markers drawing themselves in day-by-day when
/// the view appears or Replay is pressed — not a recorded video, a
/// one-time animated reveal driven by data already captured (each day's
/// place-segment centroid, persisted on `TripPlaceSegment`).
///
/// Reached from a trip's own screen, not the sidebar — a dedicated replay
/// experience, closer to "watch this trip happen" than one more page in
/// the book.
struct JourneyMapView: View {
    let trip: Trip
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    /// How many of `route`'s stops are currently revealed — animated from
    /// 0 up to `route.count` to draw the line and drop markers in order.
    @State private var revealedCount = 0
    @State private var isPlaying = false
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var route: [Trip.RouteStop] { trip.dailyRoute }
    private var revealedStops: [Trip.RouteStop] { Array(route.prefix(revealedCount)) }

    var body: some View {
        ZStack(alignment: .top) {
            if route.isEmpty {
                noRouteState
            } else {
                map
            }
            header
        }
        .background(colors.paper)
        .frame(minWidth: 700, minHeight: 560)
        .onAppear { startReplay() }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $cameraPosition) {
            if revealedStops.count >= 2 {
                MapPolyline(coordinates: revealedStops.map(\.coordinate))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [1, 0]))
            }
            ForEach(Array(revealedStops.enumerated()), id: \.element.id) { index, stop in
                Annotation(stop.placeName ?? "Day \(index + 1)", coordinate: stop.coordinate) {
                    routeMarker(dayNumber: index + 1, isLatest: index == revealedStops.count - 1)
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted))
        .onChange(of: revealedCount) { _, _ in fitCamera() }
    }

    private func routeMarker(dayNumber: Int, isLatest: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: isLatest ? 22 : 14, height: isLatest ? 22 : 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            if isLatest {
                Text("\(dayNumber)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
        .scaleEffect(isLatest ? 1 : 0.85)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isLatest)
    }

    private func fitCamera() {
        guard !revealedStops.isEmpty else { return }
        let coordinates = revealedStops.map(\.coordinate)
        let rect = coordinates.reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let padded = rect.insetBy(dx: -rect.width * 0.25 - 20000, dy: -rect.height * 0.25 - 20000)
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .rect(padded)
        }
    }

    // MARK: Replay control

    private func startReplay() {
        guard !route.isEmpty else { return }
        revealedCount = 0
        isPlaying = true
        Task {
            for i in 1...route.count {
                try? await Task.sleep(for: .milliseconds(550))
                guard isPlaying else { return }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.4)) { revealedCount = i }
                    PageTurnSound.play()
                }
            }
            await MainActor.run { isPlaying = false }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(colors.inkMuted)

            Spacer()

            VStack(spacing: 2) {
                Text(trip.name)
                    .font(Theme.titleFont(16))
                    .foregroundStyle(colors.ink)
                if !route.isEmpty {
                    Text("Day \(min(revealedCount, route.count)) of \(route.count)")
                        .font(.caption)
                        .foregroundStyle(colors.inkMuted)
                }
            }

            Spacer()

            Button {
                if isPlaying {
                    isPlaying = false
                } else {
                    startReplay()
                }
            } label: {
                Label(isPlaying ? "Stop" : "Replay", systemImage: isPlaying ? "stop.fill" : "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(route.isEmpty)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var noRouteState: some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 40))
                .foregroundStyle(colors.inkMuted)
            Text("No route to show")
                .font(Theme.titleFont(18))
                .foregroundStyle(colors.ink)
            Text("This trip's photos don't have enough location data to plot a journey.\nTry \"Refresh Name\" — it re-resolves place data too.")
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
