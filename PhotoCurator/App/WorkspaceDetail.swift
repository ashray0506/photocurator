import SwiftUI

/// Routes a sidebar selection to the right detail view. Trip-scoped
/// selections resolve the `Trip` by id each time (not captured once) so a
/// rename or edit elsewhere in the app is reflected immediately.
struct WorkspaceDetail: View {
    let selection: SidebarSelection?
    @EnvironmentObject private var scanner: LibraryScanner

    var body: some View {
        switch selection {
        case nil, .curateDashboard:
            ScanView()

        case .curateTier(let tier):
            TierReviewView(tier: tier)

        case .memories:
            MemoriesView()

        case .worldMap:
            WorldMapView()

        case .people:
            PeopleView()

        case .smartDelete:
            SmartDeleteView()

        case .tripDashboard(let tripId):
            if let trip = scanner.trips.first(where: { $0.id == tripId }) {
                TripDetailView(trip: trip)
            } else {
                missingTrip
            }

        case .tripTier(let tripId, let tier):
            if let trip = scanner.trips.first(where: { $0.id == tripId }) {
                TierReviewView(tier: tier, scope: trip)
            } else {
                missingTrip
            }

        case .tripExtras(let tripId):
            if let trip = scanner.trips.first(where: { $0.id == tripId }) {
                TierReviewView(tier: .tier3Protected, scope: trip, isExtrasMode: true)
            } else {
                missingTrip
            }

        case .tripDay(let tripId, let dayKey):
            if let trip = scanner.trips.first(where: { $0.id == tripId }) {
                TripDetailView(trip: trip, scrollToDayKey: dayKey)
            } else {
                missingTrip
            }
        }
    }

    private var missingTrip: some View {
        ContentUnavailableView("Trip not found", systemImage: "airplane",
                               description: Text("This trip may have been deleted."))
    }
}
