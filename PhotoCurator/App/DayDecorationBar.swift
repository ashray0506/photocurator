import SwiftUI

/// Decorative controls for one book page (requirement: both kids and
/// grown-ups like stickers, emoji and a lighter visual style — purely
/// cosmetic, drawn on top at export time; the underlying photos are never
/// modified).
struct DayDecorationBar: View {
    let day: Date
    let trip: Trip
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var showingStickerPicker = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(PageCaptionStyle.allCases, id: \.self) { style in
                    Button(style.displayName) {
                        scanner.setCaptionStyle(style, for: day, in: trip)
                    }
                }
            } label: {
                Label(trip.captionStyle(for: day).displayName, systemImage: "textformat")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                showingStickerPicker = true
            } label: {
                Label("Sticker", systemImage: "face.smiling")
                    .font(.caption)
            }
            .popover(isPresented: $showingStickerPicker) {
                StickerPickerPopover { emoji in
                    scanner.addSticker(PageSticker(emoji: emoji, x: 0.5, y: 0.5), to: day, in: trip)
                    showingStickerPicker = false
                }
            }

            if !trip.stickers(for: day).isEmpty {
                StickerTray(day: day, trip: trip)
            }

            Spacer()
        }
    }
}

private struct StickerPickerPopover: View {
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 4)], spacing: 4) {
            ForEach(PageSticker.palette, id: \.self) { emoji in
                Button(emoji) { onPick(emoji) }
                    .font(.title2)
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}

/// Placed stickers for a day, shown as small removable chips. A full
/// drag-to-reposition canvas is more than this needs right now — stickers
/// default to page-center and the position only matters at export, so
/// nudging via arrow controls is enough for v1.
private struct StickerTray: View {
    let day: Date
    let trip: Trip
    @EnvironmentObject private var scanner: LibraryScanner

    var body: some View {
        HStack(spacing: 4) {
            ForEach(trip.stickers(for: day)) { sticker in
                HStack(spacing: 2) {
                    Text(sticker.emoji)
                    Button {
                        scanner.removeSticker(id: sticker.id, from: day, in: trip)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }
}
