//  AlbumBookView.swift
//  The Hanji album: a two-page spread with a sheer tissue interleaf that sweeps
//  across on every page turn. No extra clicks: swipe, arrow keys, click the page,
//  or the thumbnail strip. Click a photo for full screen. Space = autoplay.
//  macOS 14+ (uses onKeyPress).

import SwiftUI
import AppKit

struct AlbumBookView: View {
    let album: AlbumModel
    var onSaveAndTidy: () -> Void

    @Environment(\.hanji) private var p
    @AppStorage private var page: Int                  // remembers last spread per album
    @State private var tissueX: CGFloat = 1.2          // fraction of page width; off-page when idle
    @State private var tissueOpacity: Double = 0
    @State private var autoplay = false
    @State private var lightbox: AlbumPhoto?
    @FocusState private var focused: Bool

    init(album: AlbumModel, onSaveAndTidy: @escaping () -> Void) {
        self.album = album
        self.onSaveAndTidy = onSaveAndTidy
        self._page = AppStorage(wrappedValue: 0, "hanji.album.\(album.id).page")
    }

    private var current: AlbumSpread? {
        album.spreads.indices.contains(page) ? album.spreads[page] : album.spreads.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            sidePanel.frame(width: 260)
            VStack(spacing: 20) {
                book
                thumbnailStrip
            }
            .frame(maxWidth: .infinity)
        }
        .padding(40)
        .background(TrackpadSwipeReader { step($0) })   // one swipe reader for book + lightbox
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; preheatNext() }
        .onKeyPress(.rightArrow) { step(+1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.space) {
            guard lightbox == nil else { return .ignored }
            autoplay.toggle(); return .handled
        }
        .onKeyPress(.escape) {
            guard let photo = lightbox else { return .ignored }
            closeLightbox(on: photo); return .handled
        }
        .task(id: autoplay) { await runAutoplay() }
        .overlay { if let photo = lightbox { lightboxView(photo) } }
        .animation(HanjiMotion.spring, value: lightbox)
    }

    // MARK: Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(album.eyebrow)
                    .font(HanjiFont.mono(12, medium: true)).tracking(0.5)
                    .foregroundStyle(p.muted)
                Text(album.title)
                    .font(HanjiFont.display(40))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(album.summary)
                    .foregroundStyle(p.muted)
                    .lineSpacing(4)
            }

            HStack(spacing: 24) {
                stat("\(album.keptCount)", "kept")
                stat(ByteCountFormatter.string(fromByteCount: album.bytesToFree, countStyle: .file), "to free")
                stat(album.miles.formatted(), "miles")
            }
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }

            Button(action: onSaveAndTidy) {
                Text("Save album & tidy up")
                    .font(HanjiFont.body(14, weight: .semibold))
                    .foregroundStyle(HanjiPalette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(p.accent))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)

            Text("The other \(album.outtakeCount.formatted()) move to Recently Deleted. Bring them back any time in 30 days.")
                .font(HanjiFont.body(12))
                .foregroundStyle(p.muted)
                .lineSpacing(3)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(HanjiFont.display(26, bold: false))
            Text(label).font(HanjiFont.body(12)).foregroundStyle(p.muted)
        }
    }

    // MARK: Book

    private var book: some View {
        HStack(spacing: 0) {
            if let s = current {
                AlbumPageView(side: .left, photos: s.left, caption: s.leftCaption, stamp: nil,
                              onOpen: { lightbox = $0 }, onTurn: { step(-1) },
                              canTurn: page > 0)
                AlbumPageView(side: .right, photos: s.right, caption: s.rightCaption, stamp: s.stamp,
                              onOpen: { lightbox = $0 }, onTurn: { step(+1) },
                              canTurn: page < album.spreads.count - 1)
                    .overlay { tissue }
                    .clipped()
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
        .background(HanjiPalette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(alignment: .topLeading) {
            // stacked page edges = the album has thickness
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(HanjiPalette.paperEdge2).offset(x: 9, y: 9)
                RoundedRectangle(cornerRadius: 4).fill(HanjiPalette.paperEdge1).offset(x: 6, y: 6)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Album, spread \(page + 1) of \(album.spreads.count)")
        .accessibilityAction(named: "Next spread") { step(+1) }
        .accessibilityAction(named: "Previous spread") { step(-1) }
    }

    /// Sheer interleaf: always peeks at the right edge; sweeps across on every turn.
    private var tissue: some View {
        GeometryReader { g in
            ZStack(alignment: .trailing) {
                Rectangle()
                    .fill(HanjiPalette.tissue.opacity(0.75))
                    .frame(width: 14)
                    .shadow(color: .black.opacity(0.06), radius: 3, x: -2)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(HanjiPalette.tissue.opacity(0.72))
                    .shadow(color: .black.opacity(0.12), radius: 12, x: -10)
                    .offset(x: tissueX * g.size.width)
                    .opacity(tissueOpacity)
            }
        }
        .environment(\.colorScheme, .light)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Thumbnails

    private var thumbnailStrip: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(album.spreads) { s in
                        let on = s.id == current?.id
                        Button { go(to: album.spreads.firstIndex(of: s) ?? 0) } label: {
                            HStack(spacing: 4) {
                                if let a = s.left.first { AlbumPhotoTile(photo: a) }
                                if let b = s.right.first { AlbumPhotoTile(photo: b) }
                            }
                            .padding(6)
                            .frame(width: 88, height: 56)
                            .background(RoundedRectangle(cornerRadius: 6).fill(HanjiPalette.paper))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? p.accent : p.line, lineWidth: on ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Go to spread \(s.id + 1)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button { autoplay.toggle() } label: {
                    Image(systemName: autoplay ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(p.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(autoplay ? "Pause slideshow" : "Play slideshow")
                Text("Spread \(page + 1) of \(album.spreads.count)")
                    .font(HanjiFont.mono(12))
                    .foregroundStyle(p.muted)
            }
        }
    }

    // MARK: Navigation

    private func step(_ delta: Int) {
        if let photo = lightbox {
            // in full screen, arrows move photo-by-photo across the whole trip
            let all = album.allPhotos
            guard let i = all.firstIndex(of: photo) else { return }
            let j = min(max(i + delta, 0), all.count - 1)
            lightbox = all[j]
            return
        }
        go(to: page + delta)
    }

    private func go(to target: Int) {
        guard !album.spreads.isEmpty else { return }
        let t = min(max(target, 0), album.spreads.count - 1)
        guard t != page else { return }
        let forward = t > page

        // 1) cover the page with tissue instantly and swap content underneath
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            tissueX = 0
            tissueOpacity = 0.96
            page = t
        }
        // 2) next frame: sweep the tissue away, revealing the new spread
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(HanjiMotion.pageTurn) {
                tissueX = forward ? -1.05 : 1.05
                tissueOpacity = 0
            }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        preheatNext()
    }

    private func preheatNext() {
        let next = album.spreads.dropFirst(page + 1).prefix(1).flatMap { $0.left + $0.right }
        PhotoThumbnailCache.shared.preheat(next.map(\.id), pointSize: CGSize(width: 480, height: 320))
    }

    private func runAutoplay() async {
        guard autoplay else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, autoplay else { return }
            if page >= album.spreads.count - 1 { autoplay = false; return }
            go(to: page + 1)
        }
    }

    // MARK: Lightbox

    private func lightboxView(_ photo: AlbumPhoto) -> some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
                .onTapGesture { closeLightbox(on: photo) }
            AlbumPhotoTile(photo: photo, fit: true, pointSize: CGSize(width: 1600, height: 1100))
                .padding(48)
                .id(photo.id)
                .transition(.opacity)
            VStack {
                HStack {
                    Spacer()
                    Button { closeLightbox(on: photo) } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
            .padding(24)
        }
    }

    private func closeLightbox(on photo: AlbumPhoto) {
        lightbox = nil
        if let i = album.spreadIndex(containing: photo), i != page {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { page = i }   // land on the spread you were viewing
        }
        focused = true
    }
}

// MARK: - One page

struct AlbumPageView: View {
    enum Side { case left, right }

    let side: Side
    let photos: [AlbumPhoto]
    let caption: String
    let stamp: TripStamp?
    var onOpen: (AlbumPhoto) -> Void
    var onTurn: () -> Void
    var canTurn: Bool

    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            let rowH = g.size.height * 0.28
            VStack(alignment: .leading, spacing: 16) {
                if let hero = photos.first {
                    photo(hero, corners: side == .left)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                let rest = Array(photos.dropFirst())
                if !rest.isEmpty {
                    HStack(spacing: 16) {
                        ForEach(rest) { photo($0, corners: false) }
                    }
                    .frame(height: rowH)
                }
                HStack(alignment: .bottom) {
                    Text(caption)
                        .font(HanjiFont.display(15, bold: false))
                        .foregroundStyle(HanjiPalette.caption)
                        .lineLimit(2)
                    Spacer()
                    if let stamp { PassportStampView(stamp: stamp) }
                }
                .frame(minHeight: 40)
            }
            .padding(.horizontal, g.size.width * 0.08)
            .padding(.vertical, g.size.height * 0.07)
        }
        .background(HanjiPalette.paper)
        .overlay(alignment: side == .left ? .trailing : .leading) { gutterShade }
        .overlay(alignment: side == .left ? .leading : .trailing) { turnHint }
        .contentShape(Rectangle())
        .onTapGesture { if canTurn { onTurn() } }        // click the paper to turn
        .onHover { hovering = $0 }
        .environment(\.colorScheme, .light)              // album paper is always light
    }

    private func photo(_ p: AlbumPhoto, corners: Bool) -> some View {
        AlbumPhotoTile(photo: p, corners: corners)
            .onTapGesture { onOpen(p) }                  // click a photo to open it
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open photo")
    }

    private var gutterShade: some View {
        LinearGradient(colors: [.clear, HanjiPalette.gutterShade.opacity(0.22)],
                       startPoint: side == .left ? .leading : .trailing,
                       endPoint: side == .left ? .trailing : .leading)
            .frame(width: 36)
            .allowsHitTesting(false)
    }

    private var turnHint: some View {
        Image(systemName: side == .left ? "chevron.left" : "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(HanjiPalette.paper)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color(hex: 0x1E2A25, opacity: 0.75)))
            .padding(side == .left ? .leading : .trailing, side == .left ? 10 : 22)
            .opacity(hovering && canTurn ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: hovering)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Photo tile

struct AlbumPhotoTile: View {
    let photo: AlbumPhoto
    var corners = false
    var fit = false
    var pointSize: CGSize? = nil
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { g in
            ZStack {
                if !fit { Rectangle().fill(HanjiPalette.photoEmpty) }
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .task(id: photo.id) {
                let size = pointSize ?? g.size
                let img = await PhotoThumbnailCache.shared.image(for: photo.id, pointSize: size)
                withAnimation(.easeOut(duration: 0.25)) { image = img }
            }
        }
        .overlay(alignment: .topLeading) { if corners { PhotoCorner().offset(x: -4, y: -4) } }
        .overlay(alignment: .bottomTrailing) { if corners { PhotoCorner().rotationEffect(.degrees(180)).offset(x: 4, y: 4) } }
    }
}

/// Classic black album photo corner.
struct PhotoCorner: View {
    var body: some View {
        Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 20, y: 0)); p.addLine(to: CGPoint(x: 0, y: 20)); p.closeSubpath()
        }
        .fill(HanjiPalette.photoCorner)
        .frame(width: 20, height: 20)
        .allowsHitTesting(false)
    }
}

// MARK: - Stamp

struct PassportStampView: View {
    let stamp: TripStamp
    var body: some View {
        VStack(spacing: 1) {
            Text(stamp.place.uppercased()).font(HanjiFont.mono(9, medium: true)).tracking(1.2)
            Text(String(stamp.year)).font(HanjiFont.mono(9, medium: true)).tracking(1.2)
        }
        .foregroundStyle(HanjiPalette.stampInk)
        .frame(width: 72, height: 72)
        .overlay(Circle().strokeBorder(HanjiPalette.stampInk, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
        .rotationEffect(.degrees(8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stamp: \(stamp.place) \(stamp.year)")
    }
}

// MARK: - Trackpad two-finger swipe

/// Turns horizontal two-finger swipes into +1 / -1. Put it in `.background` of the area that should react.
struct TrackpadSwipeReader: NSViewRepresentable {
    var onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onSwipe = onSwipe }
    func makeCoordinator() -> Coordinator { Coordinator(onSwipe: onSwipe) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.uninstall() }

    @MainActor
    final class Coordinator {
        var onSwipe: (Int) -> Void
        private weak var view: NSView?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        init(onSwipe: @escaping (Int) -> Void) { self.onSwipe = onSwipe }

        func install(on view: NSView) {
            self.view = view
            // Local event monitors always fire on the main thread, but the
            // SDK's handler closure type, `(NSEvent) -> NSEvent?`, isn't
            // itself `@MainActor`-isolated — under Swift 6 strict
            // concurrency that made every main-actor `NSView` access below
            // (`window`, `convert`, `bounds`) a warning, since the closure
            // doesn't inherit `Coordinator`'s own `@MainActor` isolation
            // just by being declared inside it.
            //
            // `MainActor.assumeIsolated` asserts what's already true at
            // runtime (this callback only ever fires on the main thread),
            // but its own closure's return value must cross back out as
            // `Sendable` — `NSEvent?` isn't, so `handle` can't return its
            // result *through* `assumeIsolated` directly. Routing the
            // consume/pass-through decision through a `Sendable` `Bool`
            // instead, and only reaching for the original `event` outside
            // the isolated block, sidesteps that without changing behavior.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                let shouldConsume = MainActor.assumeIsolated { self.handle(event) }
                return shouldConsume ? nil : event
            }
        }

        /// Returns whether the event should be consumed (swallowed) rather
        /// than passed through to the rest of AppKit.
        private func handle(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return false }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            if !event.momentumPhase.isEmpty { return true }            // ignore inertia
            if event.phase == .began { accumulated = 0; fired = false }
            accumulated += event.scrollingDeltaX
            if !fired, abs(accumulated) > 60 {
                fired = true
                onSwipe(accumulated < 0 ? +1 : -1)          // fingers left = next
            }
            if event.phase == .ended || event.phase == .cancelled { accumulated = 0; fired = false }
            return true
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Preview (placeholder tiles; real thumbnails need Photos access)

#Preview {
    let photos = (0..<14).map { AlbumPhoto(id: "preview-\($0)", takenAt: Date().addingTimeInterval(Double($0) * 7200)) }
    let spreads = AlbumPaginator.spreads(from: photos,
                                         stampForSpread: { $0 == 0 ? TripStamp(place: "Lisboa", year: 2025) : nil },
                                         caption: { _ in "Cascais, slow afternoon" })
    let album = AlbumModel(id: "preview", title: "Portugal,\nin spring", eyebrow: "ALBUM 07 · MAY 2025",
                           summary: "Six days, 412 photos. We picked the 38 that tell it best.",
                           keptCount: 38, totalCount: 412, bytesToFree: 1_400_000_000, miles: 1124, spreads: spreads)
    return HanjiShell(section: .constant(.albums), reviewCount: 374) { _ in
        AlbumBookView(album: album, onSaveAndTidy: {})
    }
    .frame(width: 1440, height: 920)
}
