import SwiftUI

/// A real 3D page-curl transition — the outgoing page rotates around its
/// leading/trailing edge (the book's spine side) and curls away with a
/// perspective transform and a shading gradient simulating the curl's own
/// shadow, revealing the incoming page underneath.
///
/// SwiftUI's declarative `.transition`/`AnyTransition` can't express this
/// (no hinge rotation, no perspective) — an earlier cross-fade + slide
/// attempt used that system and read as a generic slide, not "turning a
/// page," which was reported directly as the actual requirement. This
/// drives the effect manually with `rotation3DEffect` on an explicit
/// animated progress value instead.
///
/// `PageCurlController` owns the state (current/outgoing content, flip
/// progress, direction); `PageCurlView` renders it. Split this way because
/// the controller needs to be a reference type the caller can call
/// `transition(to:forward:)` on imperatively — a value-type `@State` can't
/// cleanly "freeze a snapshot of what's currently showing, then swap," which
/// is the one thing a reactive `onChange` can't do (by the time it fires,
/// the old content is already gone).
///
/// Drives a flip sequence: freeze the current page
/// as `outgoing`, swap `current` to the new page immediately (so it's
/// ready underneath), animate the curl, then drop the frozen copy.
@MainActor
final class PageCurlController: ObservableObject {
    @Published var current: AnyView = AnyView(EmptyView())
    @Published var outgoing: AnyView?
    @Published var curlProgress: CGFloat = 0
    @Published var forward = true

    private var isFirstSet = true

    /// Call once, whenever the page actually changes — pass the NEW
    /// content as `newContent` while `current` still holds the old one;
    /// this method does the freeze-then-swap itself.
    func transition<V: View>(to newContent: V, forward: Bool, onSound: () -> Void) {
        self.forward = forward
        if isFirstSet {
            current = AnyView(newContent)
            isFirstSet = false
            return
        }
        outgoing = current
        current = AnyView(newContent)
        curlProgress = 0
        onSound()
        withAnimation(.easeInOut(duration: 0.55)) {
            curlProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            // Only `outgoing` needs clearing — nothing reads `curlProgress`
            // once `outgoing` is nil, and the next `transition` call resets
            // it to 0 itself before animating again.
            self?.outgoing = nil
        }
    }
}

/// The view half of the above: renders `controller.current` with
/// `controller.outgoing` curling away on top when a flip is in progress.
struct PageCurlView: View {
    @ObservedObject var controller: PageCurlController

    var body: some View {
        ZStack {
            controller.current

            if let outgoing = controller.outgoing {
                outgoing
                    .rotation3DEffect(
                        .degrees(Double(controller.curlProgress) * (controller.forward ? -150 : 150)),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: controller.forward ? .leading : .trailing,
                        anchorZ: 0,
                        perspective: 0.55
                    )
                    .shadow(color: Theme.espresso.opacity(0.25 * Double(1 - controller.curlProgress)),
                           radius: 12, x: controller.forward ? -8 : 8, y: 0)
                    .overlay(curlShading)
                    .opacity(controller.curlProgress > 0.96 ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var curlShading: some View {
        let intensity = 1 - abs(Double(controller.curlProgress) - 0.5) * 2
        return LinearGradient(
            colors: [.clear, Theme.espresso.opacity(0.18 * intensity), .clear],
            startPoint: controller.forward ? .leading : .trailing,
            endPoint: controller.forward ? .trailing : .leading
        )
    }
}
