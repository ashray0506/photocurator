import SwiftUI

/// The trip-detail hero dashboard: a dark cover card with the trip's real
/// stats, plus a tier breakdown scoped to this trip's own photos — not the
/// whole-library numbers the Curate tab shows. Requested directly by the
/// user from a reference screenshot; built against live `Trip`/`PhotoRecord`
/// data rather than placeholder numbers.
struct TripHeroCard: View {
    let trip: Trip
    let days: [(day: Date, photos: [PhotoRecord])]
    let photos: [PhotoRecord]
    var onOpenBook: (() -> Void)?
    /// Opt-in AI naming (see `AITripNamer`), surfaced right on the page the
    /// trip's name already lives on — the rename sheet's "Suggest with AI"
    /// existed already, but only behind a right-click a user had to already
    /// know about. nil hides the button outright (no saved API key).
    var onSuggestName: (() async -> Void)?
    var isSuggestingName = false

    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    private var tier1Count: Int { photos.filter { $0.tier == .tier1 }.count }
    private var tier2Count: Int { photos.filter { $0.tier == .tier2 }.count }
    private var tier3Count: Int { photos.filter { $0.tier == .tier3Protected }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            coverCard
            tierRow
        }
    }

    // MARK: Cover card

    private var coverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                statChip(icon: "calendar", text: dateRangeText)
                statChip(icon: "clock", text: "\(days.count.formatted()) Days")
                if let places = placesText {
                    statChip(icon: "mappin.and.ellipse", text: places)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(trip.name)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(colors.ink)
                if let onSuggestName {
                    Button {
                        Task { await onSuggestName() }
                    } label: {
                        if isSuggestingName {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Nostalgic name", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .disabled(isSuggestingName)
                }
            }

            Text(summaryText)
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
                .lineLimit(3)

            // Scrolls to the day sections already on this same screen —
            // this card lives at the top of TripDetailView, not a separate
            // screen, so there is nowhere else to "navigate" to.
            Button {
                onOpenBook?()
            } label: {
                Text("Browse Days")
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

    private var dateRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: trip.startDay)
        let end = formatter.string(from: trip.endDay)
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        return start == end ? "\(start), \(yearFormatter.string(from: trip.startDay))"
                            : "\(start) – \(end), \(yearFormatter.string(from: trip.endDay))"
    }

    private var placesText: String? {
        let names = trip.distinctPlaceNames
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? names[0] : "\(names.count) Places"
    }

    private var summaryText: String {
        var parts: [String] = ["\(photos.count.formatted()) photos analyzed on-device."]
        if tier1Count + tier2Count > 0 {
            parts.append("\((tier1Count + tier2Count).formatted()) are flagged for review.")
        } else {
            parts.append("Your photo book is ready to review.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Tier row

    /// Stat display only — not a navigation link. A trip-scoped tier review
    /// screen (review/delete just this trip's Tier 1/2 photos, the way the
    /// whole-library Curate tab does) doesn't exist yet; linking these cards
    /// to the whole-library `TierReviewView` would show the wrong counts,
    /// so until that screen is built these are read-only, matching numbers
    /// already visible via Curate for the library as a whole.
    private var tierRow: some View {
        HStack(spacing: 14) {
            tierCard(title: "Junk", count: tier1Count,
                    detail: "Pocket photos, dark blurs, screenshots")
            tierCard(title: "Redundant", count: tier2Count,
                    detail: "Near-duplicate shots from this trip")
            tierCard(title: "Keeps", count: tier3Count,
                    detail: "Favorites, people, and standout shots")
        }
    }

    private func tierCard(title: String, count: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(colors.inkMuted)
            Text(count.formatted())
                .font(.title2.weight(.medium))
                .foregroundStyle(colors.ink)
            Text(detail)
                .font(.caption)
                .foregroundStyle(colors.inkMuted)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(colors, cornerRadius: 10)
    }
}
