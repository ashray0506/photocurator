import SwiftUI

/// A single toast with an optional action — "Rescued · Undo", "Deleted ·
/// Show in Recently Deleted". One at a time, auto-dismissing, matching the
/// reversible-action feedback pattern used throughout the review screens.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var actionLabel: String?
    var action: (() -> Void)?
    var isAffirmative: Bool = true   // true: green check icon; false: amber/info icon

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, actionLabel: String? = nil, isAffirmative: Bool = true,
             action: (() -> Void)? = nil, duration: Duration = .seconds(5)) {
        dismissTask?.cancel()
        let toast = Toast(text: text, actionLabel: actionLabel, action: action, isAffirmative: isAffirmative)
        current = toast
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if self?.current?.id == toast.id { self?.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// The toast's visual presentation, overlaid at the bottom of the window.
struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.isAffirmative ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(toast.isAffirmative ? .green : .orange)
                    Text(toast.text)
                        .font(.callout)
                    if let label = toast.actionLabel {
                        Button(label) {
                            toast.action?()
                            center.dismiss()
                        }
                        .font(.callout.weight(.semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: center.current)
        .allowsHitTesting(center.current != nil)
    }
}
