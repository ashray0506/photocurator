import SwiftUI

@main
struct PhotoCuratorApp: App {
    @StateObject private var scanner = LibraryScanner()
    @StateObject private var toasts = ToastCenter()

    var body: some Scene {
        WindowGroup("PhotoCurator") {
            RootView()
                .environmentObject(scanner)
                .environmentObject(toasts)
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

/// Top-level shell: a persistent left sidebar (every trip, with its own
/// Dashboard/Tier/Day rows) and a detail pane that routes to whichever
/// section is selected. Replaces an earlier bottom-TabView layout — trips
/// need to always be visible and drillable without leaving the sidebar,
/// matching the reference layout the user asked for.
///
/// The Trip Wrap-Up banner (the proactive "you just got back, want to
/// clean this up?" moment — PRD-adjacent, not in the original spec: Apple
/// Photos' Memories and Google Photos' trip highlights do this on their
/// own) sits above the split view so it is visible regardless of what's
/// selected.
private struct RootView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var toasts: ToastCenter
    @State private var wrapUpCandidate: TripDetector.Candidate?
    @State private var dismissedCandidateID: String?
    @State private var showingWrapUp = false
    @State private var selection: SidebarSelection? = .curateDashboard

    var body: some View {
        VStack(spacing: 0) {
            if let candidate = wrapUpCandidate, candidate.id != dismissedCandidateID {
                TripWrapUpBanner(candidate: candidate,
                                 onOpen: { showingWrapUp = true },
                                 onDismiss: { dismissedCandidateID = candidate.id })
            }

            NavigationSplitView {
                WorkspaceSidebar(selection: $selection)
            } detail: {
                NavigationStack {
                    WorkspaceDetail(selection: selection)
                }
            }
        }
        .overlay { ToastOverlay(center: toasts) }
        .sheet(isPresented: $showingWrapUp) {
            if let candidate = wrapUpCandidate {
                TripWrapUpView(candidate: candidate) {
                    showingWrapUp = false
                    wrapUpCandidate = nil
                }
            }
        }
        .task {
            // A light incremental scan on launch, so a just-finished
            // trip's photos are picked up without the user remembering to
            // press "Rescan". Gated on having scanned at least once before:
            // a genuinely first launch must go through Photos access and
            // the backup reminder first, not an automatic background scan.
            // Once past that, the cache (PRD §13) keeps this cheap — only
            // photos added since the last scan are actually analysed.
            if scanner.hasScannedBefore {
                scanner.start()
            }
        }
        .onReceive(scanner.$phase) { phase in
            guard phase == .finished else { return }
            wrapUpCandidate = scanner.recentUnsavedTripCandidate()
        }
    }
}
