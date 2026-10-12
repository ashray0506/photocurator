import SwiftUI

/// M1's screen: start a scan, watch progress, read the dry-run report.
///
/// There is deliberately no delete button anywhere in this milestone. The
/// tier review screens and their one-button-per-tier actions arrive in M5
/// (PRD §6), after the M1 report has been used to tune thresholds.
struct ScanView: View {
    @EnvironmentObject private var scanner: LibraryScanner

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let report = scanner.report {
                ReportView(report: report)
            } else {
                placeholder
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if scanner.isRunning {
                    Button("Cancel", role: .cancel) { scanner.cancel() }
                } else {
                    Button(scanner.report == nil ? "Scan Library" : "Rescan") {
                        scanner.start()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library scan")
                        .font(.title2.weight(.semibold))
                    Text(scanner.phase.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if case .analyzing(let done, let total) = scanner.phase, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .progressViewStyle(.linear)
            } else if scanner.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if case .failed(let message) = scanner.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No scan yet")
                .font(.headline)
            Text("PhotoCurator reads your library and sorts photos into tiers.\nThis is a dry run: nothing is deleted or changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
