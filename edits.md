# Edits — PhotoCurator redesign

**Design reference:** `hanji/HANJI_PRD.md` (palette, fonts, layouts, behaviour), with starter SwiftUI files in `hanji/Theme` and `hanji/Album`. These edits say *what* to change. The PRD sections in brackets say *how it should look and behave*.

Work through the sections in order. Build after each one, and commit when it compiles cleanly.

---

## 1. Replace the sidebar with top tabs

Right now the sidebar mixes tools (Scan, Smart Delete) with fun views (Map, Memories), and Scan and Smart Delete overlap.

- Remove the sidebar. Use the Hanji top bar instead: **Albums · Map · Stamps · People** as pill tabs (⌘1–⌘4), plus a **Review** button with a count on the right. [PRD §3]
- **Albums** replaces Memories and becomes the home screen. **Review** merges Scan & Curate with Smart Delete. **Stamps** moves out of World Map into its own tab.
- Move Settings into the macOS Settings window (⌘,), and add the Background picker there (Library green / Plaster / Ink).
- Set the accent colour app-wide (`.tint` + `AccentColor` in Assets) so there's no system blue anywhere.
- Use a hidden title bar with the top bar matching the background, so the white title bar goes away.

## 2. Give trips one home: the trip workspace

The four trip-scoped views (trip dashboard, trip tier review, trip day, trip extras) don't get their own screens or a sidebar. [PRD §3.1]

- Opening a trip from anywhere pushes one **trip workspace** with two modes, **Album · Curate**, and a breadcrumb back to Albums (⌘[).
- **Trip dashboard** → the album's side panel (title, summary, kept / to free / miles).
- **Trip day** → days become chapters in the album. Add a Book / Contact sheet toggle to scan every day at once.
- **Trip tier review** → Curate mode.
- **Trip extras** → a "Back pocket" drawer of receipts, tickets, screenshots and videos.
- Use one route, `TripRoute(id, mode, day, filter)`, on each tab's `NavigationStack`. Keep the existing views' logic and re-host their UI.

## 3. Make every screen answer "what do I do next?"

The Scan screen shows stats but no clear path, and people won't understand "Keeps 48,835, Low confidence 25,679."

- **Albums home:** lead with one sentence and one button, e.g. *"We found 50 trips. Build albums and free up 12 GB →"*. Below it, show postcard-style trip cards. [PRD §5.3]
- **Review screen:** [PRD §5.4]
  - Tier cards go in flow order (Junk → Redundant → Unsure → Keeps), at equal height and aligned. Today the Junk card is shorter and offset. Dim cards with 0 items.
  - Rename "Low confidence (kept)" to **"Unsure — we kept these to be safe."**
  - Move "Copy report", the scan time, cache info and the dry-run flag under a collapsed *Analysis details*. They're developer info, not hero content.
  - Merge Rescan / Force Rescan into one Rescan button with a menu. Two equal pills make people hesitate.

## 4. Build the core flow: Trip → Album → Clean

This is the heart of the app.

1. **Pick a trip.** Use postcard cards with a cover photo, place, dates and photo count.
2. **Relive it.** The trip opens in Album mode, using the paper album book from `AlbumBookView` [PRD §5.1]:
   - A tissue sweep on each page turn.
   - Swipe, arrow keys, clicking the page, or the thumbnail strip to turn pages.
   - Click a photo for full screen. Space starts autoplay.
3. **Curate.** Auto-pick the best 20–40 photos (sharpness, faces, variety) as already kept. In Curate mode, review the Unsure photos one at a time. [PRD §3.1, "Keys are mode-scoped"]
   - → or K keeps, ← or X removes, Z undoes, and a two-finger swipe does either.
   - The arrow keys only mean keep/remove in Curate mode. In Album mode they turn pages.
4. **Clean the rest.** "Save album & tidy up":
   - Create the album in Photos and move the outtakes to Recently Deleted through PhotoKit.
   - Show the space saved as a celebration: a stamp lands and the GB counter ticks up. [PRD §5.2]

Always say that items go to Recently Deleted and can be recovered for 30 days. That trust message matters more than any feature. Never hard-delete, and never touch favourites, hidden photos or shared-album photos.

## 5. Make the map belong to the theme

The default Apple Maps blue clashes with the UI. [PRD §5.5]

- Use `.mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))`.
- Make custom pins: accent-colour dots with a paper-coloured ring, sized by photo count.
- Cluster nearby pins into a count bubble that zooms in on click. Today the US west coast and Italy are overlapping blobs, and labels like "ys in United States" are cut off. Labels must never be truncated.
- Clicking a pin opens the trip's postcard, and its button opens the trip in **Album mode**.

## 6. Lean into nostalgia with restraint

- **Typography:** use **Fraunces 72pt** (SemiBold / Regular) for titles and captions, **SF Pro** for the interface, and **DM Mono** for dates, counts and stamp text. The font files are in `photoapp/fonts/`; bundle the four .ttf files. English only. [PRD §4, §7]
- **Texture:** add a very subtle paper grain (2–3% opacity), on the album paper and postcard cards only, not the dark background. Postcard cards get a thin stamp-perforation border.
- **Stamps:** use one stamp-ink colour, each stamp tilted between ±3° and ±6°, with the angle seeded by the trip so it stays stable. [PRD §5.6]
- **Motion:** use spring animations for stamps landing, cards flipping and counters ticking up. Use the shared `HanjiMotion` values everywhere; don't hand-tune springs per view.

## 7. Polish details

- Use consistent radii (12 on buttons, 8 on postcard cards, 4 on the album, 6 on thumbnails) and one shadow style per surface.
- **Check contrast:** body text must be ≥ 4.5:1. Persimmon on Library green is fine. On the Plaster background, use the accent for fills and icons, not small text.
- **Empty states:** warm, plain English with no emoji. [PRD §5.7] For example:
  - *"No junk found. Your library's already in good shape."*
  - *"Every trip has an album. Nice work — 12.4 GB freed so far."*
- Respect Reduce Motion: the tissue sweep becomes a simple crossfade.
