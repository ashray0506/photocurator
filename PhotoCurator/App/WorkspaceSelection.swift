import Foundation

/// What the sidebar can select, driving the detail pane. Two independent
/// axes: which trip (or none, for the whole-library Curate screens) and
/// which section within it.
enum SidebarSelection: Hashable {
    case curateDashboard                  // whole-library scan/report
    case curateTier(Tier)                 // whole-library tier review
    /// The Memories browser — a grid of trip cards. The sidebar lists
    /// this as a single destination rather than one row per trip; every
    /// trip-specific case below is reached by opening a card from there,
    /// not by expanding the sidebar.
    case memories
    /// The cross-trip overview: a world map of every visited city plus
    /// "passport stamps" for each city/country and a total-distance stat
    /// — requested directly: "section that like stamps from all the
    /// places visited... map, or just stamps of all cities and total
    /// miles if there is any way."
    case worldMap
    case people
    case smartDelete
    case tripDashboard(tripId: String)
    case tripTier(tripId: String, tier: Tier)
    case tripDay(tripId: String, dayKey: String)
    /// Tier 3 survivors in this trip that are NOT in the book's chosen
    /// selection and not protected for a real reason (favorite, known
    /// person, edited, album member) — the long tail of "kept because
    /// unsure" photos a trip never actually needed. Deliberately not a
    /// `Tier` case: those are persisted per-photo and covered by the
    /// "Tier 3 never deletable" safety tests, which must stay true for the
    /// real tier. This is a trip-scoped, recomputed-on-demand view over
    /// the same photos, not a new stored tier.
    case tripExtras(tripId: String)
}
