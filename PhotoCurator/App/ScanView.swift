import SwiftUI

/// Scan, watch progress, read the dry-run report, then drill into a tier to
/// review and act on it (PRD §4, §6). The scan and report stay read-only;
/// `TierReviewView` is the only screen with a delete button.
///
/// Three distinct states, deliberately not sharing one header:
/// - First scan ever: no report, nothing running yet — a calm explanation
///   and one button, nothing to measure progress against.
/// - Scanning (first time or a rescan): a progress strip is the only thing
///   that matters; everything else is noise until it finishes.
/// - Done: the report (`ReportView`'s hero card) already states the photo
///   count, duration and "dry run" status — a second header repeating
///   "Library scan / Scan complete" above it was pure redundancy (visибly
///   doubled up visibly in testing), so once a report exists this view
///   gets out of the way entirely and lets the report be the whole screen.
struct ScanView: View {
    @EnvironmentObject private var scanner: LibraryScanner

    var body: some View {
        Group {
            if scanner.isRunning {
                scanningState
            } else if let report = scanner.report {
                ReportView(report: report)
            } else {
                firstScanState
            }
        }
        .navigationTitle("Scan & Curate")
        .toolbar {
            if scanner.isRunning {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel", role: .cancel) { scanner.cancel() }
                }
            } else if scanner.report == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan Library") { scanner.start() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                // A `Menu(_:primaryAction:)` split button was tried here
                // first (one click to rescan, a dropdown for Force Rescan)
                // but rendered as an empty, unclickable space in this
                // toolbar placement — confirmed from a user screenshot
                // showing nothing where the button should be. Two plain
                // toolbar items is slightly less slick but actually
                // visible and clickable.
                ToolbarItem(placement: .secondaryAction) {
                    Button("Force Rescan") { scanner.start(ignoreCache: true) }
                        .help("Re-analyse every photo from scratch, ignoring the cache")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Rescan") { scanner.start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .navigationDestination(for: Tier.self) { tier in
            TierReviewView(tier: tier)
        }
    }

    // MARK: Scanning (first time or a rescan)

    private var scanningState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accent)
            Text(scanner.phase.label)
                .font(.callout)
                .foregroundStyle(.secondary)

            if case .analyzing(let done, let total) = scanner.phase, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                Text("\(done.formatted()) of \(total.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            }

            if case .failed(let message) = scanner.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.rust)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: First scan ever

    private var firstScanState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text("Your library, organized")
                .font(Theme.titleFont(22))
            Text("PhotoCurator reads your photos and sorts them into tiers —\nso you can see what's worth keeping before anything changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label("This is a dry run: nothing is deleted until you confirm.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            if case .failed(let message) = scanner.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.rust)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
