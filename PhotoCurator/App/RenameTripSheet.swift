import SwiftUI

/// Renames an existing trip — reachable from the sidebar's per-trip
/// context menu (right-click a trip → Rename…). "Suggest with AI" only
/// appears once a key is saved in Settings (`APIKeyStore.load() != nil`)
/// — never shown, let alone called, without one. See `AITripNamer`'s doc
/// comment for exactly what's sent (place names, country, date range —
/// never photos) when it's used.
struct RenameTripSheet: View {
    let trip: Trip
    let onConfirm: (String) -> Void
    @State private var draftName: String
    @State private var hasAPIKey = false
    @State private var isSuggesting = false
    @State private var suggestionError: String?
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

            if hasAPIKey {
                Button {
                    Task { await suggestWithAI() }
                } label: {
                    if isSuggesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Suggest with AI", systemImage: "sparkles")
                    }
                }
                .disabled(isSuggesting)
                if let suggestionError {
                    Text(suggestionError).font(.caption).foregroundStyle(.orange)
                }
            }

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
        .task { hasAPIKey = APIKeyStore.load() != nil }
    }

    private func suggestWithAI() async {
        isSuggesting = true
        suggestionError = nil
        defer { isSuggesting = false }
        do {
            let stops = LibraryScanner.namingStops(from: trip.placeSegmentsByDay)
            let country = stops.first?.country
            let places = stops.map(\.name)
            let suggestion = try await AITripNamer().suggestName(
                places: places, country: country, startDay: trip.startDay, endDay: trip.endDay)
            draftName = suggestion
        } catch {
            suggestionError = error.localizedDescription
        }
    }
}
