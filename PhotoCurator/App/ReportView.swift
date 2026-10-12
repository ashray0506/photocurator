import SwiftUI

/// The dry-run summary (PRD §4.4) and M1's read-only tier report.
struct ReportView: View {
    let report: ScanReport
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                dryRunNotice
                totals
                tierSection
                peopleSection
                clusteringSection
                daysSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // PRD §9.1: the user must see that nothing has changed yet.
    private var dryRunNotice: some View {
        Label {
            Text("Dry run — nothing has been deleted or changed.")
                .font(.callout.weight(.medium))
        } icon: {
            Image(systemName: "checkmark.shield.fill")
        }
        .foregroundStyle(.green)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var totals: some View {
        HStack(spacing: 28) {
            stat("Photos", report.totalPhotos.formatted())
            stat("Duration", report.formattedDuration)
            stat("From cache", report.photosFromCache.formatted())
            stat("Days", report.days.count.formatted())
            Spacer()
            Button {
                copyReport()
            } label: {
                Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tierSection: some View {
        section("Tiers") {
            ForEach(report.tiers) { summary in
                NavigationLink(value: summary.tier) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(summary.tier.displayName)
                                .font(.headline)
                            Spacer()
                            Text(summary.count.formatted())
                                .font(.headline.monospacedDigit())
                            Text(summary.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(summary.reasons, id: \.reason) { entry in
                            HStack {
                                Text(entry.reason.displayName)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.count.formatted())
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 14)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var peopleSection: some View {
        section("People") {
            row("Face clusters", report.faceClusterCount)
            row("Known people", report.knownPersonCount)
            row("Photos containing people", report.photosWithPeople)
        }
    }

    private var clusteringSection: some View {
        section("Clustering") {
            row("Clusters", report.clusterCount)
            row("With more than one photo", report.multiPhotoClusterCount)
            row("Largest cluster", report.largestClusterSize)
            // PRD §12, M1: judge outfit-splitting accuracy from this number.
            row("Extra clusters from outfit splitting", report.totalOutfitSplits)
            HStack {
                Text("Special-landscape threshold")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.3f", report.specialLandscapeThreshold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var daysSection: some View {
        section("Days") {
            HStack {
                Text("GPS coverage").foregroundStyle(.secondary)
                Spacer()
                Text(gpsCoverageText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            // Most recent first: the oldest days in a long-running library
            // are often the ones with the least metadata (no GPS on old
            // photos, in particular), so showing oldest-first in a
            // truncated list made the whole library look GPS-less even
            // when recent years are well covered. The overall stat above
            // is the number to trust either way.
            ForEach(report.days.sorted { $0.day > $1.day }.prefix(60)) { day in
                HStack {
                    Text(day.day, format: .dateTime.year().month().day())
                        .font(.callout.monospacedDigit())
                    if !day.hasLocation {
                        Text("no GPS")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text("\(day.photoCount.formatted()) photos")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(day.clusterCount.formatted()) clusters")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if day.outfitSplitCount > 0 {
                        Text("+\(day.outfitSplitCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }
            if report.days.count > 60 {
                Text("…and \(report.days.count - 60) more days. Use Copy report for the full list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gpsCoverageText: String {
        let total = report.daysTotal
        guard total > 0 else { return "0 of 0 days" }
        let percent = Int(100.0 * Double(report.daysWithLocation) / Double(total))
        return "\(report.daysWithLocation.formatted()) of \(total.formatted()) days (\(percent)%)"
    }

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.formatted()).monospacedDigit()
        }
        .font(.callout)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
