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
            HStack(spacing: 16) {
                statChip(icon: "calendar", text: dateRangeText)
                statChip(icon: "clock", text: "\(days.count.formatted()) Days")
                if let places = placesText {
                    statChip(icon: "mappin.and.ellipse", text: places)
                }
            }

            Text(trip.name)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)

            Text(summaryText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)

            // Scrolls to the day sections already on this same screen —
            // this card lives at the top of TripDetailView, not a separate
            // screen, so there is nowhere else to "navigate" to.
            Button {
                onOpenBook?()
            } label: {
                Label("Jump to Book Draft", systemImage: "book.closed.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
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
            tierCard(title: "Tier 1: Junk", count: tier1Count,
                    detail: "Pocket photos, dark blurs, screenshots",
                    icon: "trash.fill", tint: .red)
            tierCard(title: "Tier 2: Redundant", count: tier2Count,
                    detail: "Near-duplicate shots from this trip",
                    icon: "square.stack.3d.up.fill", tint: .orange)
            tierCard(title: "Tier 3: Keeps", count: tier3Count,
                    detail: "Favorites, people, and standout shots",
                    icon: "star.fill", tint: .green)
        }
    }

    private func tierCard(title: String, count: Int, detail: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.components(separatedBy: ": ").last ?? title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(count.formatted())
                .font(.title2.weight(.bold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
