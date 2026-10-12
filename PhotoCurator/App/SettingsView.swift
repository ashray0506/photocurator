import SwiftUI

/// Threshold controls (PRD §9.6). Every value has a sensible default and
/// there is a single "Reset to defaults" button.
struct SettingsView: View {
    @EnvironmentObject private var scanner: LibraryScanner

    var body: some View {
        Form {
            Section("Known person") {
                Stepper("Minimum photos: \(scanner.settings.knownPersonMinPhotos)",
                        value: $scanner.settings.knownPersonMinPhotos, in: 2...100)
                Stepper("Minimum distinct days: \(scanner.settings.knownPersonMinDays)",
                        value: $scanner.settings.knownPersonMinDays, in: 1...30)
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
        .frame(width: 460, height: 560)
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
