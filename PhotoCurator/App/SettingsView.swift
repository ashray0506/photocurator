import SwiftUI

/// Threshold controls (PRD §9.6). Every value has a sensible default and
/// there is a single "Reset to defaults" button.
struct SettingsView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    var body: some View {
        // `.formStyle(.grouped)` alone renders through the same gray
        // system material as the sidebar's old `.listStyle(.sidebar)` —
        // same "just grey" complaint applies here. Hiding the form's own
        // background and painting the theme's warm linen behind it fixes
        // that without giving up `Form`'s row/section layout.
        Form {
            // Moved to the top: this is the screen the user is in
            // specifically to find the API key field for, and it was
            // previously the very last section, below six others.
            aiNamingSection

            Section("Known person") {
                Stepper("Minimum photos: \(scanner.settings.knownPersonMinPhotos)",
                        value: $scanner.settings.knownPersonMinPhotos, in: 2...100)
                Stepper("Minimum distinct days: \(scanner.settings.knownPersonMinDays)",
                        value: $scanner.settings.knownPersonMinDays, in: 1...30)
                // Lower = stricter (fewer, tighter matches; the same person
                // may split across more cards). Higher = looser (fewer
                // cards, but different people risk merging into one).
                // Exposed directly because the right value depends on each
                // library's own photos — there's no single constant that
                // avoids both "split into many" and "mixed up with someone
                // else" for everyone, so this needs to be tunable, not
                // hardcoded. Takes effect on the next rescan.
                VStack(alignment: .leading) {
                    Text("Face match strictness: \(String(format: "%.2f", scanner.settings.faceMatchThreshold))")
                    Slider(value: $scanner.settings.faceMatchThreshold, in: 0.35...0.9)
                    Text("Lower = stricter (fewer mix-ups, more duplicate people). Higher = looser (fewer duplicates, more mix-ups). Rescan to apply.")
                        .font(.caption2)
                        .foregroundStyle(colors.inkMuted)
                }
            }

            Section("Protection") {
                VStack(alignment: .leading) {
                    Text("Special landscapes: top \(Int((1 - scanner.settings.specialLandscapePercentile) * 100))%")
                    Slider(value: $scanner.settings.specialLandscapePercentile, in: 0.5...0.99)
                }
            }

            Section("Clustering") {
                Stepper("Photos kept per cluster: \(scanner.settings.perClusterCap)",
                        value: $scanner.settings.perClusterCap, in: 1...5)
                VStack(alignment: .leading) {
                    Text("Maximum time gap: \(Int(scanner.settings.clusterMaxTimeGap / 60)) min")
                    Slider(value: $scanner.settings.clusterMaxTimeGap, in: 60...3600, step: 60)
                }
                VStack(alignment: .leading) {
                    Text("Maximum distance: \(Int(scanner.settings.clusterMaxDistance)) m")
                    Slider(value: $scanner.settings.clusterMaxDistance, in: 50...2000, step: 50)
                }
            }

            Section("Junk classification") {
                VStack(alignment: .leading) {
                    Text("Confidence floor: \(scanner.settings.junkConfidenceMin, format: .number.precision(.fractionLength(2)))")
                    Slider(value: $scanner.settings.junkConfidenceMin, in: 0.5...0.99)
                    Text("Below this confidence a photo is kept rather than classified as junk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            homeLocationsSection

            Section {
                Button("Reset to defaults") {
                    scanner.settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(colors.paper)
        .tint(Theme.accent)
        .frame(width: 460, height: 620)
    }

    /// The one deliberate opt-in exception to this app's on-device design
    /// — see `AITripNamer`'s doc comment for exactly what leaves the
    /// device and when. Key lives in the Keychain, never in a plist.
    private var aiNamingSection: some View {
        Section {
            SecureField("Anthropic API key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveAPIKey)
            HStack {
                Button("Save Key") { saveAPIKey() }
                    .disabled(apiKeyDraft.isEmpty)
                if hasStoredKey {
                    Button("Remove Key", role: .destructive) {
                        APIKeyStore.clear()
                        apiKeyDraft = ""
                        hasStoredKey = false
                    }
                }
            }
            Text(hasStoredKey
                 ? "A key is saved. \"Suggest with AI\" will appear when renaming a trip."
                 : "Optional. Without a key, trip names are built entirely on-device from place and country data — nothing ever leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI Naming (Optional)")
        }
        .task { hasStoredKey = APIKeyStore.load() != nil }
    }

    private func saveAPIKey() {
        APIKeyStore.save(apiKeyDraft)
        hasStoredKey = !apiKeyDraft.isEmpty
        apiKeyDraft = ""
    }

    /// Not every GPS-dense date range is a trip: home locations (and
    /// anywhere within their radius) are excluded from trip detection.
    /// Auto-detected from density, user-editable, user-addable.
    private var homeLocationsSection: some View {
        Section("Home locations") {
            if scanner.homeLocations.isEmpty {
                Text("None detected yet. Home locations are found automatically from a library scan, or you can add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.homeLocations) { home in
                HomeLocationRow(home: home,
                                onUpdate: { scanner.updateHomeLocation($0) },
                                onRemove: { scanner.removeHomeLocation(id: home.id) })
            }
            Button("Detect Home Locations") {
                scanner.detectHomeLocations()
            }
            .disabled(scanner.records.isEmpty)
        }
    }
}

private struct HomeLocationRow: View {
    let home: HomeLocation
    let onUpdate: (HomeLocation) -> Void
    let onRemove: () -> Void
    @State private var radiusKm: Double

    init(home: HomeLocation, onUpdate: @escaping (HomeLocation) -> Void, onRemove: @escaping () -> Void) {
        self.home = home
        self.onUpdate = onUpdate
        self.onRemove = onRemove
        self._radiusKm = State(initialValue: home.radius / 1000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(home.name).font(.callout.weight(.medium))
                    if home.isAutoDetected {
                        Text("Auto-detected · \(home.distinctDayCount.formatted()) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Added manually")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("Radius: \(Int(radiusKm)) km").font(.caption)
                Slider(value: $radiusKm, in: 5...200, step: 5) { _ in
                    var updated = home
                    updated.radius = radiusKm * 1000
                    onUpdate(updated)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
