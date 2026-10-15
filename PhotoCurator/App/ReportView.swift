import SwiftUI

/// The dry-run summary (PRD §4.4) and M1's read-only tier report.
struct ReportView: View {
    let report: ScanReport
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroCard
                tierSection
                DisclosureGroup("Analysis details") {
                    VStack(alignment: .leading, spacing: 22) {
                        peopleSection
                        clusteringSection
                        daysSection
                    }
                    .padding(.top, 12)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                statChip(icon: "photo.stack", text: "\(report.totalPhotos.formatted()) Photos")
                statChip(icon: "calendar", text: "\(report.days.count.formatted()) Days")
                statChip(icon: "checkmark.shield", text: "Dry run")
            }

            Text("Your library")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(colors.ink)

            Text("Scanned in \(report.formattedDuration), \(report.photosFromCache.formatted()) from cache. Nothing is deleted until you confirm a tier.")
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
                .lineLimit(3)

            Button {
                copyReport()
            } label: {
                Text(copied ? "Copied" : "Copy report")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(colors.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(colors.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(colors, cornerRadius: 14)
    }

    private func statChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(colors.inkMuted)
    }

    // MARK: Tiers

    private var tierSection: some View {
        HStack(spacing: 14) {
            ForEach(report.tiers) { summary in
                NavigationLink(value: summary.tier) {
                    tierCard(summary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tierCard(_ summary: ScanReport.TierSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.tier.shortName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colors.inkMuted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(colors.inkMuted)
            }
            Text(summary.count.formatted())
                .font(.title2.weight(.medium))
                .foregroundStyle(colors.ink)
            Text(summary.formattedSize)
                .font(.caption)
                .foregroundStyle(colors.inkMuted)
            if let topReason = summary.reasons.first {
                Text("\(topReason.reason.displayName) · \(topReason.count.formatted())")
                    .font(.caption2)
                    .foregroundStyle(colors.inkMuted)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(colors, cornerRadius: 10)
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
