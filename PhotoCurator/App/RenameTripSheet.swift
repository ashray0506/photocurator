import SwiftUI

/// Renames an existing trip — reachable from the sidebar's per-trip
/// context menu (right-click a trip → Rename…).
struct RenameTripSheet: View {
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
