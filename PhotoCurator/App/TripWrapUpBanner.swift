import SwiftUI

/// The proactive "you just got back, want to clean this up?" moment —
/// the piece this app was missing versus Apple Photos' Memories or Google
/// Photos' trip highlights, which surface this kind of thing on their own
/// rather than waiting for the user to go looking for a review screen.
struct TripWrapUpBanner: View {
    let candidate: TripDetector.Candidate
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "airplane.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Trip Wrap-Up ready")
                    .font(.callout.weight(.semibold))
                Text("\(dateRangeText) · \(candidate.photoIds.count.formatted()) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Review") { onOpen() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.blue.opacity(0.15)), alignment: .bottom)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var dateRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: candidate.startDay)
        if Calendar.current.isDate(candidate.startDay, inSameDayAs: candidate.endDay) {
            return start
        }
        return "\(start) – \(formatter.string(from: candidate.endDay))"
    }
}
