import Foundation

/// What the sidebar can select, driving the detail pane. Two independent
/// axes: which trip (or none, for the whole-library Curate screens) and
/// which section within it.
enum SidebarSelection: Hashable {
    case curateDashboard                  // whole-library scan/report
    case curateTier(Tier)                 // whole-library tier review
    case tripDashboard(tripId: String)
    case tripTier(tripId: String, tier: Tier)
    case tripDay(tripId: String, dayKey: String)
}
