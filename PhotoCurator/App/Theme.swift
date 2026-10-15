import SwiftUI

/// Shared visual language: one named palette, fixed roles, used everywhere
/// — nothing improvised per-screen. Replaces the previous "vintage travel
/// poster" pass, which got the mood right but not the system: the sidebar's
/// *selection* highlight was never retinted and kept showing raw AppKit
/// system blue (`List(selection:)` paints that independently of row
/// content), and accent/mustard was being reused for icons, pins and
/// selected text all at once with no fixed meaning — reported directly as
/// "the system accent colour leaking through" and "define one palette and
/// use it everywhere."
///
/// Four earlier passes were tried and replaced: a plain light "kraft paper"
/// minimal look (too flat), a noir near-black theme ("just dark, not
/// nostalgic"), a pale warm-linen/sage look ("just grey"), and a teal/
/// mustard "vintage poster" pass (closer, but the system-blue leak and
/// unfixed color roles were the actual remaining problem, not the hues
/// themselves). This pass keeps a similar warm-nostalgic mood but with an
/// explicit, named palette and roles that don't shift meaning screen to
/// screen.
enum Theme {
    // MARK: Palette (fixed hex values — do not reach for `Color.red`/
    // `.green`/`.orange`/etc. anywhere in the app; every color used must
    // trace back to one of these names, so the palette can move in one
    // place without a later audit turning up strays again).

    /// 60%: warm cream — the base background almost everything sits on.
    static let cream = Color(red: 0.965, green: 0.937, blue: 0.886)
    /// 60%: light sand — a card/surface a touch lighter than cream, for
    /// anything resting "on top of" the page (cards, rows, sheets).
    static let sand = Color(red: 0.984, green: 0.969, blue: 0.933)
    /// 10%: terracotta — the one color that means act/delete/primary
    /// action. Never used for a merely decorative icon or a stamp color;
    /// if it's terracotta, it's asking for a tap that does something.
    static let terracotta = Color(red: 0.769, green: 0.384, blue: 0.227)
    /// 30%: Aegean blue — explore/info: navigation, links, map pins,
    /// anything that takes you somewhere or tells you something, never an
    /// action that changes data.
    static let aegean = Color(red: 0.180, green: 0.478, blue: 0.549)
    /// 10%: sunflower — highlight/emphasis only (a selection wash, a
    /// stamp's ink, a badge). Never icon fill and never text color — the
    /// brief's own contrast rule: gold reads as a highlight, not type.
    static let sunflower = Color(red: 0.902, green: 0.682, blue: 0.271)
    /// Positive/keep: olive. The one color meaning "this is protected / a
    /// keeper / a good outcome" — replaces ad hoc `Color.green` wherever a
    /// screen meant "kept" or "safe."
    static let olive = Color(red: 0.482, green: 0.522, blue: 0.314)
    /// Negative/remove, alongside terracotta for destructive emphasis in
    /// side-by-side keep/discard contexts (swipe review, tier comparison)
    /// — replaces ad hoc `Color.red`.
    static let rust = Color(red: 0.72, green: 0.30, blue: 0.24)

    static let espresso = Color(red: 0.180, green: 0.165, blue: 0.141)

    // MARK: Tuscan dusk (dark mode)

    /// Deep olive-brown, not near-black — a dark *room*, not a void. The
    /// earlier noir pass over-corrected to near-black and read as "just
    /// dark, not nostalgic"; this stays warm and brown-toned instead.
    static let duskPaper = Color(red: 0.165, green: 0.141, blue: 0.125)
    static let duskSand = Color(red: 0.200, green: 0.169, blue: 0.145)
    static let duskInk = Color(red: 0.949, green: 0.914, blue: 0.847)

    /// Kept as the one semantic "accent" for call sites that genuinely
    /// want the primary-action color without threading `ThemeColors`
    /// through (e.g. a plain `Label` icon tint) — always terracotta, never
    /// reassigned per-screen.
    static let accent = terracotta

    /// Trip names and big section titles read like a travel-journal
    /// headline — a serif, not the system sans used for body/UI text.
    static func titleFont(_ size: CGFloat) -> Font {
        .custom("New York", size: size, relativeTo: .title).weight(.medium)
    }
}

/// Scheme-aware surface/text roles built from `Theme`'s fixed palette —
/// light mode is warm cream/sand/espresso, dark mode is "Tuscan dusk"
/// (deep olive-brown/espresso-adjacent sand/pale cream text). Semantic
/// accent roles (`terracotta`/`aegean`/`sunflower`/`olive`) are NOT
/// repeated here: they don't change between light and dark, so call sites
/// read them straight off `Theme`.
struct ThemeColors {
    let paper: Color
    let paperRaised: Color
    let ink: Color
    let inkMuted: Color
    let hairline: Color

    init(_ scheme: ColorScheme) {
        switch scheme {
        case .dark:
            paper = Theme.duskPaper
            paperRaised = Theme.duskSand
            ink = Theme.duskInk
            inkMuted = Theme.duskInk.opacity(0.62)
            hairline = Theme.duskInk.opacity(0.16)
        default:
            paper = Theme.cream
            paperRaised = Theme.sand
            ink = Theme.espresso
            inkMuted = Theme.espresso.opacity(0.62)
            hairline = Theme.espresso.opacity(0.14)
        }
    }
}

extension View {
    /// A page leaf lit from above — a soft, warm shadow beneath rather
    /// than a flat bordered card, like a print resting on a sunlit table.
    /// One shadow style, one corner-radius convention used throughout:
    /// 16 for cards (the default here), 10 for buttons/controls.
    func themedCard(_ colors: ThemeColors, cornerRadius: CGFloat = 16) -> some View {
        self
            .background(colors.paperRaised, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(colors.hairline, lineWidth: 1))
            .shadow(color: Theme.espresso.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}
