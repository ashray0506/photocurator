import SwiftUI

/// Trip list: saved trips plus candidates detected from day grouping, place
/// segmentation and date gaps together (PRD §10, full design — see
/// `TripDetector`). This is the screen that answers "build a photo album
/// for my trips".
struct TripsView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var candidates: [TripDetector.Candidate] = []
    @State private var namingCandidate: TripDetector.Candidate?

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
                    Button("Find Trips") { candidates = scanner.detectTripCandidates() }
                        .disabled(scanner.records.isEmpty)
                }
            }
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip)
            }
            .sheet(item: $namingCandidate) { candidate in
                NameTripSheet(candidate: candidate, scanner: scanner) { name, candidate, resolved in
                    scanner.saveTrip(name: name, candidate: candidate, placeSegmentsByDay: resolved)
                    candidates.removeAll { $0.id == candidate.id }
                    namingCandidate = nil
                }
            }
            .task { if scanner.records.isEmpty == false { candidates = scanner.detectTripCandidates() } }
        }
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
                            tripRow(name: trip.name, startDay: trip.startDay, endDay: trip.endDay,
                                   photoCount: trip.photoIds.count)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { scanner.deleteTrip(id: trip.id) }
                        }
                    }
                }
            }

            if !candidates.isEmpty {
                Section("Detected (not yet saved)") {
                    ForEach(candidates) { candidate in
                        Button {
                            namingCandidate = candidate
                        } label: {
                            tripRow(name: Trip.suggestedName(startDay: candidate.startDay, endDay: candidate.endDay),
                                   startDay: candidate.startDay, endDay: candidate.endDay,
                                   photoCount: candidate.photoIds.count,
                                   hasLocation: candidate.hasAnyLocation)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if candidates.isEmpty && scanner.trips.isEmpty {
                Text("No trips detected yet. Tap \"Find Trips\" above, or scan a larger library — trips need at least a few days with several photos each, separated by a quieter stretch or a change of location.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tripRow(name: String, startDay: Date, endDay: Date,
                         photoCount: Int, hasLocation: Bool = true) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(startDay, format: .dateTime.year().month().day())
                + Text(" – ")
                + Text(endDay, format: .dateTime.year().month().day())
            }
            .font(.callout)
            Spacer()
            Text("\(photoCount.formatted()) photos")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if !hasLocation {
                Image(systemName: "location.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Resolves place names (PRD §10.3) as soon as the sheet opens, so the user
/// sees a real suggested name — e.g. "Seoul, South Korea" — before deciding
/// whether to keep it, rather than only after saving.
private struct NameTripSheet: View {
    let candidate: TripDetector.Candidate
    let scanner: LibraryScanner
    let onConfirm: (String, TripDetector.Candidate, [String: [TripPlaceSegment]]) -> Void

    @State private var draftName: String = ""
    @State private var isResolvingPlaces = true
    @State private var resolvedSegments: [String: [TripPlaceSegment]] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name this trip").font(.title3.weight(.semibold))
            Text("\(candidate.dayCount) days · \(candidate.photoIds.count.formatted()) photos")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isResolvingPlaces {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up places…").font(.caption).foregroundStyle(.secondary)
                }
            }

            TextField("Trip name", text: $draftName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save Trip") {
                    onConfirm(draftName, candidate, resolvedSegments)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .task {
            draftName = Trip.suggestedName(startDay: candidate.startDay, endDay: candidate.endDay)
            resolvedSegments = await scanner.resolvePlaceNames(for: candidate.segmentsByDay)
            isResolvingPlaces = false

            let placeNames = resolvedSegments.values.flatMap { $0 }.compactMap(\.placeName)
            guard !placeNames.isEmpty else { return }
            var seen = Set<String>()
            let distinct = placeNames.filter { seen.insert($0).inserted }
            draftName = Trip.suggestedName(startDay: candidate.startDay,
                                           endDay: candidate.endDay,
                                           placeNames: distinct)
        }
    }
}
