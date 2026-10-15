import SwiftUI

@main
struct PhotoCuratorApp: App {
    @StateObject private var scanner = LibraryScanner()
    @StateObject private var toasts = ToastCenter()

    /// Belt-and-suspenders alongside `.restorationBehavior(.disabled)`
    /// below: repeated testing found launches where AppKit's own window
    /// restoration silently produced no window at all, even with that
    /// scene modifier set — `_reopenWindowsAsNecessaryIncludingRestorableState`
    /// logged `hasPersistentStateToRestore=1` and ran through both
    /// "Restoring windows" bookkeeping calls without ever creating a new
    /// window. `-ApplePersistenceIgnoreState YES` (normally a launch
    /// argument, confirmed to fix it when passed via `open --args`) is the
    /// actual flag AppKit's restoration subsystem checks before touching
    /// `NSApp`; setting it this way applies for every ordinary double-click
    /// launch too, not just ones a developer remembers to pass a flag to.
    init() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        Self.verifyHanjiFontsLoaded()
    }

    /// Debug-only check (PRD §7) that the four bundled Hanji fonts — not
    /// system fallbacks — actually registered via `ATSApplicationFontsPath`.
    /// `HanjiFont` itself degrades silently to a system font if a lookup
    /// fails, which is the right behavior at runtime (nothing breaks) but
    /// means a broken font bundle would otherwise go unnoticed rather than
    /// being caught immediately in a debug build.
    private static func verifyHanjiFontsLoaded() {
        #if DEBUG
        for name in ["Fraunces72pt-SemiBold", "Fraunces72pt-Regular", "DMMono-Regular", "DMMono-Medium"] {
            assert(NSFont(name: name, size: 12) != nil, "Hanji font not bundled correctly: \(name)")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("PhotoCurator") {
            RootView()
                .environmentObject(scanner)
                .environmentObject(toasts)
                .frame(minWidth: 1100, idealWidth: 1440, minHeight: 760, idealHeight: 920)
                .task {
                    scanner.loadTrips()
                    scanner.loadHomeLocations()
                    scanner.loadPeople()
                }
        }
        // Hanji §4: no native title bar — `HanjiTopBar` draws the whole
        // chrome itself (brand, tabs, Review button) and insets its own
        // leading edge to clear the traffic lights.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        // Repeated testing this session hit launches where macOS's own
        // window-state restoration silently produced no window at all
        // (AppKit logged `_restoreWindowWithRestoration:` completing with
        // `window=0x0, error=(null)` — no error, just nothing). This app
        // has no multi-window session worth restoring anyway, so disabling
        // restoration outright removes the failure mode rather than
        // working around it.
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environmentObject(scanner)
        }
    }
}

/// Top-level shell: `HanjiShell`'s top pill tabs replace the old sidebar
/// (Hanji PRD §3 — "Navigation is top pill tabs. There is no sidebar.").
/// Each `HanjiSection` wraps the matching existing screen in its own
/// `NavigationStack`, so in-app pushes (a Memories card opening a trip, a
/// trip's own tier/extras links) work the same way they did under the
/// sidebar, just without the sidebar itself.
///
/// Trip-scoped navigation (`SidebarSelection.tripDashboard`/`.tripTier`/
/// `.tripDay`/`.tripExtras`) still routes through the existing
/// `TripDetailView`/`TierReviewView` screens for now — §3.1's single
/// `TripRoute` / `TripWorkspaceView` (Album · Curate modes, Back pocket)
/// is Phase 2 scope, not this phase's "wire the existing views into the
/// sections" bar.
///
/// The Trip Wrap-Up banner (the proactive "you just got back, want to
/// clean this up?" moment — PRD-adjacent, not in the original spec: Apple
/// Photos' Memories and Google Photos' trip highlights do this on their
/// own) sits above the shell so it is visible regardless of which tab is
/// showing.
private struct RootView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var toasts: ToastCenter
    @State private var wrapUpCandidate: TripDetector.Candidate?
    @State private var dismissedCandidateID: String?
    @State private var showingWrapUp = false
    @State private var section: HanjiSection = .albums

    private var reviewCount: Int {
        scanner.records.filter { $0.tier == .tier1 || $0.tier == .tier2 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if let candidate = wrapUpCandidate, candidate.id != dismissedCandidateID {
                TripWrapUpBanner(candidate: candidate,
                                 onOpen: { showingWrapUp = true },
                                 onDismiss: { dismissedCandidateID = candidate.id })
            }

            HanjiShell(section: $section, reviewCount: reviewCount) { section in
                NavigationStack {
                    tabContent(for: section)
                        .navigationDestination(for: SidebarSelection.self) { pushed in
                            WorkspaceDetail(selection: pushed)
                        }
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

    /// Maps each Hanji tab to the existing screen it replaces (PRD §3).
    /// Stamps points at the same `WorldMapView` as Map for now — splitting
    /// the passport-stamps section out into its own screen is Phase 5
    /// scope (§5.6), not this phase's.
    @ViewBuilder
    private func tabContent(for section: HanjiSection) -> some View {
        switch section {
        case .albums:
            MemoriesView()
        case .map, .stamps:
            WorldMapView()
        case .people:
            PeopleView()
        case .review:
            ReviewTabView()
        }
    }
}

/// §3's Review tab replaces Scan & Curate + Smart Delete with "a single
/// tidy-up flow." The real merge (§5.4: tier cards in flow order, renamed
/// labels, one Rescan button with a Force Rescan menu) is Phase 4 scope;
/// for Phase 1's "wire the existing views into the sections" bar, both
/// existing screens are reachable here without data loss or a half-built
/// merge standing in for the real one.
private struct ReviewTabView: View {
    private enum Sub: String, CaseIterable, Identifiable {
        case scan = "Scan & Curate", smartDelete = "Smart Delete"
        var id: String { rawValue }
    }
    @State private var sub: Sub = .scan

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sub) {
                ForEach(Sub.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            switch sub {
            case .scan: ScanView()
            case .smartDelete: SmartDeleteView()
            }
        }
    }
}
