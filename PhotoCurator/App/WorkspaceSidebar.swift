import SwiftUI

/// The persistent left sidebar: every saved trip, and — for the selected
/// trip — its Dashboard / Tier 1-3 / day-by-day rows, matching the
/// reference layout the user asked for (trips always visible, drill into a
/// trip's own sections without leaving the sidebar).
struct WorkspaceSidebar: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @Binding var selection: SidebarSelection?
    @State private var expandedTripId: String?
    @State private var isFindingTrips = false
    @State private var renamingTrip: Trip?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("Scan & Curate", systemImage: "checkmark.circle")
                    .tag(SidebarSelection.curateDashboard)
            }

            Section {
                if scanner.trips.isEmpty {
                    Text("No trips yet — tap \"Find Trips\" below, after scanning your library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scanner.trips) { trip in
                        tripDisclosure(trip)
                    }
                }
            } header: {
                HStack {
                    Text("Your Trips")
                    Spacer()
                    Button {
                        Task { await findTrips() }
                    } label: {
                        if isFindingTrips {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkle.magnifyingglass")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(scanner.records.isEmpty || isFindingTrips)
                    .help("Find Trips")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PhotoCurator")
        .task {
            guard !scanner.records.isEmpty, scanner.trips.isEmpty else { return }
            await findTrips()
        }
        .sheet(item: $renamingTrip) { trip in
            RenameTripSheet(trip: trip) { newName in
                scanner.renameTrip(id: trip.id, to: newName)
                renamingTrip = nil
            }
        }
    }

    private func findTrips() async {
        isFindingTrips = true
        defer { isFindingTrips = false }
        await scanner.autoSaveDetectedTrips()
    }

    private func tripDisclosure(_ trip: Trip) -> some View {
        DisclosureGroup(isExpanded: isExpandedBinding(for: trip.id)) {
            Label("Dashboard", systemImage: "square.grid.2x2")
                .tag(SidebarSelection.tripDashboard(tripId: trip.id))

            tierRow(trip, .tier1, "Tier 1 · Junk", "trash", .red)
            tierRow(trip, .tier2, "Tier 2 · Redundant", "square.stack.3d.up", .orange)
            tierRow(trip, .tier3Protected, "Tier 3 · Keeps", "star", .green)

            ForEach(dayEntries(for: trip), id: \.key) { entry in
                Label(entry.label, systemImage: "calendar")
                    .font(.caption)
                    .tag(SidebarSelection.tripDay(tripId: trip.id, dayKey: entry.key))
            }
        } label: {
            Label(trip.name, systemImage: "airplane")
                .lineLimit(1)
        }
        .contextMenu {
            Button("Rename…") { renamingTrip = trip }
            Button("Delete", role: .destructive) { scanner.deleteTrip(id: trip.id) }
        }
    }

    private func tierRow(_ trip: Trip, _ tier: Tier, _ title: String, _ icon: String, _ tint: Color) -> some View {
        let count = scanner.photos(in: trip).filter { $0.tier == tier }.count
        return HStack {
            Label(title, systemImage: icon).foregroundStyle(tint)
            Spacer()
            Text(count.formatted()).font(.caption).foregroundStyle(.secondary)
        }
        .tag(SidebarSelection.tripTier(tripId: trip.id, tier: tier))
    }

    private struct DayEntry { var key: String; var label: String; var date: Date }

    private func dayEntries(for trip: Trip) -> [DayEntry] {
        let calendar = Calendar.current
        let photos = scanner.photos(in: trip)
        let days = Set(photos.compactMap { $0.dayStart(calendar: calendar) }).sorted()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return days.map { DayEntry(key: Trip.dayKey($0), label: formatter.string(from: $0), date: $0) }
    }

    private func isExpandedBinding(for tripId: String) -> Binding<Bool> {
        Binding(
            get: { expandedTripId == tripId },
            set: { expandedTripId = $0 ? tripId : nil }
        )
    }
}
