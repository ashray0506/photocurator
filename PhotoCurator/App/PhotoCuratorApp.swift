import SwiftUI

@main
struct PhotoCuratorApp: App {
    @StateObject private var scanner = LibraryScanner()

    var body: some Scene {
        WindowGroup("PhotoCurator") {
            RootView()
                .environmentObject(scanner)
                .frame(minWidth: 820, minHeight: 600)
                .task {
                    scanner.loadTrips()
                    scanner.loadHomeLocations()
                }
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(scanner)
        }
    }
}

/// Top-level tabs: the scan/curate workflow and the trip-book workflow are
/// separate concerns sharing one scanner, so each gets its own tab rather
/// than being squeezed into one screen.
private struct RootView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Curate", systemImage: "checkmark.circle") }
            TripsView()
                .tabItem { Label("Trips", systemImage: "airplane") }
        }
    }
}
