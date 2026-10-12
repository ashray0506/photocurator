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

            Section {
                Button("Reset to defaults") {
                    scanner.settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}
