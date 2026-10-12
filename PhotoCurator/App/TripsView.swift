import SwiftUI

/// Trip list: every detected trip is saved automatically with a
/// best-guess name (geocoded place, or a date range when there's no GPS) —
/// trips simply appear here rather than requiring an explicit tap-to-name
/// step before they exist. Rename anytime by tapping a trip.
struct TripsView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var isFindingTrips = false
    @State private var renamingTrip: Trip?

    var body: some View {
        NavigationStack {
            Group {
                if scanner.records.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Trips")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await findTrips() }
                    } label: {
                        if isFindingTrips {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Find Trips")
                        }
                    }
                    .disabled(scanner.records.isEmpty || isFindingTrips)
                }
            }
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip)
            }
            .sheet(item: $renamingTrip) { trip in
                RenameTripSheet(trip: trip) { newName in
                    scanner.renameTrip(id: trip.id, to: newName)
                    renamingTrip = nil
                }
            }
            .task {
                guard !scanner.records.isEmpty else { return }
                await findTrips()
            }
        }
    }

    private func findTrips() async {
        isFindingTrips = true
        defer { isFindingTrips = false }
        await scanner.autoSaveDetectedTrips()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "airplane")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Scan your library first")
                .font(.headline)
            Text("Trips are detected from the photos found in a library scan.\nGo to the Curate tab and run a scan.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            if !scanner.trips.isEmpty {
                Section("Your Trips") {
                    ForEach(scanner.trips) { trip in
                        NavigationLink(value: trip) {
                            tripRow(trip)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { scanner.deleteTrip(id: trip.id) }
                            Button("Rename") { renamingTrip = trip }
                                .tint(.blue)
                        }
                        .contextMenu {
                            Button("Rename") { renamingTrip = trip }
                            Button("Delete", role: .destructive) { scanner.deleteTrip(id: trip.id) }
                        }
                    }
                }
            } else if isFindingTrips {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for trips…").foregroundStyle(.secondary)
                }
            } else {
                Text("No trips detected yet. Tap \"Find Trips\" above, or scan a larger library — trips need at least a few days with several photos each, separated by a quieter stretch or a change of location.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tripRow(_ trip: Trip) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.headline)
                Text(trip.startDay, format: .dateTime.year().month().day())
                + Text(" – ")
                + Text(trip.endDay, format: .dateTime.year().month().day())
            }
            .font(.callout)
            Spacer()
            Text("\(trip.photoIds.count.formatted()) photos")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if trip.distinctPlaceNames.isEmpty {
                Image(systemName: "location.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct RenameTripSheet: View {
    let trip: Trip
    let onConfirm: (String) -> Void
    @State private var draftName: String
    @Environment(\.dismiss) private var dismiss

    init(trip: Trip, onConfirm: @escaping (String) -> Void) {
        self.trip = trip
        self.onConfirm = onConfirm
        self._draftName = State(initialValue: trip.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename trip").font(.title3.weight(.semibold))
            TextField("Trip name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm(draftName) }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { onConfirm(draftName) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
