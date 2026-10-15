# PRD — Hanji redesign (PhotoCurator)

**Status:** Ready to build · **Platform:** macOS 14+ · SwiftUI · PhotoKit
**Goal:** Turn a "scan & delete" utility into a travel-journal app that feels like flipping a real paper album, while making it easier than ever to keep the best photos and let go of the rest.

> **Role of this file:** the design layer (look, layout, behaviour). The list of changes to make lives in `../edits.md`, which points back to sections here.

---

## 0. Prompt to paste into Claude Code (VS Code)

> Read `edits.md` (the changes to make, in order), then `hanji/HANJI_PRD.md` (the design they must follow) and the Swift files in `hanji/` (Theme/ and Album/). Before changing anything:
> 1. Explore this project and tell me: the app entry point, the current sidebar/navigation view, the views for Scan & Curate, Memories, World Map, People, Smart Delete, Settings, the trip/album model types, how photos are loaded (PhotoKit wrapper), and how deletion currently works.
> 2. Propose a mapping from those to the PRD's sections (§3, and §3.1 for the trip-scoped views: trip dashboard, trip tier review, trip day, trip extras) and a step-by-step plan following §8 phases. Wait for my OK.
>
> Then implement phase by phase. Rules: reuse existing models, loaders and deletion code instead of duplicating (delete `PhotoThumbnailCache.swift` if we already have a loader); keep the existing curation/scan engine untouched; build after each phase and fix all warnings; no system blue anywhere; never hard-delete — always PhotoKit `deleteAssets` (goes to Recently Deleted). Commit at the end of each phase.

---

## 1. Problem

- The current UI clashes: macOS blue selection + gold text on beige, a white title bar against beige content, default blue Apple Maps.
- Navigation mixes tools and memories, and Scan & Curate overlaps Smart Delete.
- The home screen shows numbers ("Keeps 48,835, Low confidence 25,679") but no next step.
- Albums don't feel like albums. The emotional payoff (seeing a trip beautifully) is missing, so the cleanup feels like a chore.

## 2. Design principles

1. **A paper album, a modern app.** Real-feeling cream pages, photo corners, stamps and a tissue interleaf, framed by sleek, quiet chrome inspired by modern Japanese and Korean design. The UI is **English only**: no Korean or Japanese text anywhere.
2. **Zero-friction viewing.** Never require a click just to *see* photos. Every interaction is optional delight (swipe, keys, autoplay).
3. **One clear next step per screen.**
4. **Trust.** Every delete says where photos go (Recently Deleted) and that they can be recovered for 30 days.

## 3. Information architecture

| New section | Replaces | Notes |
|---|---|---|
| **Albums** (home) | Memories + trip detection | Grid of trip albums → opens `AlbumBookView` |
| **Map** | World Map | Restyled; pins open the trip's album |
| **Stamps** | Passport Stamps (was inside World Map) | Own tab |
| **People** | People | Restyle only |
| **Review** (button, top-right) | Scan & Curate + Smart Delete | Single tidy-up flow with count badge |
| Settings | Settings | Move to the macOS Settings scene (⌘,) |

Navigation is top pill tabs (`HanjiShell` / `HanjiTopBar`). There is no sidebar. ⌘1–⌘4 switch tabs.

### 3.1 Trip workspace (where trip-scoped views live)

**Decision:** trips are reached by **one push** from Albums (or any other entry point) into a single **trip workspace** with **two modes, Album · Curate**, plus a **Back pocket** drawer. There's no trip sidebar and there are no separate trip screens.

**Why:**
- A sidebar adds a second navigation system that appears and disappears (layout jump) and takes width from the spread.
- Pushing four sibling screens recreates the old dashboard maze.
- People come to a trip with one of three intents (relive, refine, keep the odd bits), so the structure follows those intents.

**Today's views → Hanji**

| Intent | Today's view | In the trip workspace |
|---|---|---|
| Relive | Trip dashboard | **Album mode** side panel: eyebrow, title, summary, kept / to free / miles, status. Not its own screen. |
| Relive | Trip day | **Days are chapters** of the album. The thumbnail strip is grouped by day with day labels. A **Book / Contact sheet** toggle in Album mode shows all days as a scannable grid; clicking a photo or day there returns to Book on that spread. |
| Refine | Trip tier review | **Curate mode.** Tiers (Junk → Redundant → Unsure → Picks), swap picks in and out, and "Save album & tidy up" as the main action. |
| Keep odd bits | Trip extras | **Back pocket:** a small tab on the last spread (and a toolbar button) that opens a right-side drawer of receipts, tickets, screenshots and videos. Items can be kept with the trip or released. Never a full screen. |

**Trip header** (replaces the tab bar's content area while inside a trip):
- Breadcrumb `Albums › Portugal, in spring`. Back with ⌘[ or swipe-from-edge.
- A segmented control **Album · Curate** (⌘⇧A / ⌘⇧C), with a badge on Curate showing the unresolved (Unsure) count.
- A **Back pocket** button with an item count.
- The top pill tabs stay visible, and the current tab stays highlighted.

**Keys are mode-scoped:**
- **Album mode:** ← / → turn pages, Space toggles autoplay, and Return or a click opens a photo.
- **Curate mode:** a one-photo-at-a-time review card. **→ or K** keeps the photo, **← or X** sends it to outtakes, **↑ / ↓** move between candidates without deciding, **Z** undoes, and a two-finger swipe right or left keeps or removes. The decision animates the photo into the album pile or the outtake pile with a spring. A progress line reads "12 of 40 unsure left".
- Auto-picks (best 20–40 by sharpness, faces and variety) start out kept. The user only has to look at Unsure photos and any they choose to swap.

**Save button behaviour:**
- In **Album mode** the side-panel button reads **"Review & save"**. With 0 unresolved items it saves directly (§5.2). Otherwise it switches to Curate, filtered to Unsure, with a one-line hint.
- In **Curate mode** it reads **"Save album & tidy up"**, with the Recently Deleted / 30-day line underneath.

**Every entry point lands in the same workspace:**

| From | Opens |
|---|---|
| Albums card | Album mode, at the last-viewed spread |
| Map pin / postcard | Album mode |
| Map day label, search hit for a date | Album mode, on that day's first spread |
| Stamps | Album mode, on the spread carrying that stamp |
| Review tab, trip row | Curate mode, filtered to that trip |
| "50 trips found" banner | First uncurated trip, in Curate mode |

**Implementation:**
- One route type: `TripRoute(id: Trip.ID, mode: TripMode = .album, day: Date? = nil, filter: CurateFilter? = nil)`, with `enum TripMode { case album, curate }`.
- Each top tab owns a `NavigationStack(path:)`. Pushing `TripRoute` shows `TripWorkspaceView`, which switches between `AlbumBookView` and the existing tier-review view (restyled), and hosts the Back pocket drawer as an `.inspector`.
- Mode and day are part of the route, so deep links, back/forward and state restoration all work for free. The last mode used per trip is remembered.
- Existing trip dashboard, tier review, day and extras views: keep their logic and data. Re-host the UI as described above, and delete the old standalone screens once they're re-hosted.

**Success check:** from launch, seeing a trip takes ≤ 2 clicks and cleaning a trip takes ≤ 3, and there's no screen the user has to "find".

## 4. Visual system (`HanjiTheme.swift`)

**Chrome background:** user setting, default *Library green*.

| Token | Library green | Plaster | Ink |
|---|---|---|---|
| background | `#1E2A25` | `#DAD4C8` | `#16181D` |
| text | `#EFEBE1` | `#24272A` | `#ECEAE4` |
| muted | `#AEB8B0` | `#52575A` | `#A7A9AE` |
| line | `#34433C` | `#C4BCAE` | `#2B2E35` |
| accent | `#D98A5F` persimmon | `#C0643A` | `#C9A15A` brass |

**Album paper (constant):** paper `#F7F5EF`, edges `#ECE8DE` / `#E2DDD1`, caption `#4E534F`, photo corners `#2E3A34`, stamp ink `#A44A26`, tissue `#FCFBF7`.

**Type — pairing A, "Travel journal":**

| Role | Font | PostScript name | Used for |
|---|---|---|---|
| Display | Fraunces 72pt SemiBold | `Fraunces72pt-SemiBold` | Album and page titles, big stats |
| Display (light) | Fraunces 72pt Regular | `Fraunces72pt-Regular` | Photo captions, stat numbers, secondary headings |
| UI | SF Pro (system, not bundled) | `.system(...)` | Tabs, buttons, body text, labels |
| Detail | DM Mono Regular | `DMMono-Regular` | Dates, times, photo counts, "Spread 2 of 8" |
| Detail (strong) | DM Mono Medium | `DMMono-Medium` | Stamp text (place, miles, year), eyebrows like "ALBUM 07 · MAY 2025" |

- Fraunces and DM Mono are OFL fonts from Google Fonts and must be bundled (§7). SF Pro comes with macOS.
- Suggested sizes: page title 40, album card title 22, captions 15, UI body 14, labels 12, mono details 11–12 with +0.5 tracking, and stamp text 9–10 with +1.2 tracking.
- **Code change required:** `HanjiFont` in `HanjiTheme.swift` still references the old Gowun Batang / IBM Plex Sans KR names. Replace it with `display(size, bold:)` → Fraunces72pt-SemiBold/Regular (fallback `.system(design: .serif)`), `body(size, weight:)` → `.system(size:weight:)`, and a new `mono(size, medium:)` → DMMono-Regular/Medium (fallback `.system(design: .monospaced)`). Then switch eyebrows, dates, counts and stamp text to `mono`.
- **Remove all Korean text from the Hanji files:**
  - The "여" brand mark and the "Yeohaeng" name in `HanjiTopBar`: use the app's own name, with a simple monogram or the app icon.
  - The "앨범" eyebrow: it becomes "ALBUM 07 · MAY 2025".
  - `TripStamp.localScript` and its line in `PassportStampView`: delete them.

**Rules:**
- `.tint(accent)` at the root, plus `AccentColor` in Assets set to the accent, so there's no system blue.
- The accent is only for primary actions, the active state and stamps. Text on the accent uses `#1B1A17`.
- Use `.windowStyle(.hiddenTitleBar)` and a toolbar background that matches the chrome, so there's no white title bar.
- Radius: 12 for buttons, 4 for the album, 6 for thumbnails. Postcard cards use 8. Use one shadow style per surface (album: large soft drop; cards: `0 8 20 -12` black 35%).
- Motion: `HanjiMotion.spring` for UI, stamps landing, counters ticking up and cards flipping; `pageTurn` (0.7s) for pages. Don't hand-tune spring values elsewhere.
- Texture: a very subtle paper grain (2–3% opacity noise image, tiled) on **album paper and postcard cards only**, never on the dark chrome background.
- Contrast: body text must be ≥ 4.5:1. Accent text is fine on the dark grounds (persimmon on Library green ≈ 5:1). On Plaster, use accent for fills and icons, not small text.

## 5. Features & requirements

### 5.1 Album book (`AlbumBookView.swift`) — P0
- Two-page spread on cream paper, with gutter shading, stacked page edges and a drop shadow.
- **Tissue interleaf:** a thin vellum strip always peeks at the right edge. On every page turn, a sheer sheet covers the page and sweeps away (forward → left, back → right) in 0.7s. There's never a separate "lift tissue" action.
- **Turning pages, all equivalent:** two-finger trackpad swipe, ← / → keys, clicking the paper of the left/right page (hover shows a chevron), the thumbnail strip, and the accessibility actions.
- **Click a photo** → full-window lightbox. ← / → and swipe move through *all* trip photos; Esc or a click outside closes it and lands on the spread holding that photo.
- **Space** toggles autoplay (4s per spread, stops at the end).
- Remembers the last spread per album (`@AppStorage hanji.album.<id>.page`).
- Preheats the next spread's thumbnails, so turns never show empty frames.
- Light haptic on each turn (Force Touch trackpads).
- The side panel shows the eyebrow, title, summary, *kept / to free / miles* stats, **Save album & tidy up** (⌘↩), and the trust line.

### 5.2 Save album & tidy up — P0
1. Create or update a `PHAssetCollection` named after the trip (album title) holding the kept assets.
2. Delete outtakes with `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(outtakes) }`. macOS shows its own confirmation and items go to Recently Deleted.
3. On success, a stamp lands (spring + slight rotation), and "1.4 GB freed" counts up. Mark the trip done.
4. On cancel or failure, nothing changes and a calm inline message appears.
- **Never** delete favourited, hidden, edited-in-other-app or shared-album assets. Respect the existing "low confidence → keep" rule.

### 5.3 Albums home — P0
- Grid of postcard-style trip cards: cover photo on paper with photo corners and a thin stamp-perforation border, the place as the title in Fraunces, dates and "38 of 412" in DM Mono, and a status chip (*To curate* / *Done*).
- The top banner shows one sentence and one button, e.g. "50 trips found. Build albums and free up 12 GB →", which opens the first uncurated trip.

### 5.4 Review (merged Scan & Smart Delete) — P1
- Lead with one sentence and one primary button, e.g. "374 photos across 6 trips are ready to tidy. Review →".
- Tier cards in flow order (Junk → Redundant → Unsure → Keeps), **equal height and aligned**, with zero-count cards dimmed to 50% and not clickable.
- Rename "Low confidence (kept)" to **"Unsure — we kept these to be safe."**
- One "Rescan" button with a menu holding "Force rescan", never two equal buttons. "Copy report", scan time, cache stats and the dry-run flag go under a collapsed *Analysis details* (developer info, not hero content).

### 5.5 Map — P1
- `.mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))`.
- Custom pins: an accent dot with a paper-coloured (`#F7F5EF`) ring, sized by photo count. Overlapping pins cluster into a count bubble that zooms in on click (fixes today's overlapping US west coast and Italy pins). Labels are never truncated (e.g. today's "ys in United States").
- Clicking a pin opens a postcard popover. Its button opens the trip in **Album mode** (§3.1), not the clean flow.

### 5.6 Stamps — P2
- A grid of `PassportStampView`s, one per country/city. All use the single stamp ink colour, each rotated randomly but stably (seeded by the trip id) between ±3° and ±6°, so they look hand-placed but calm. **Code change:** `PassportStampView` currently uses a fixed 8°; make the rotation a parameter.
- Stamp text: place name, miles and year in DM Mono Medium, in English only.
- Keep "Generate AI captions" here as a secondary button.

### 5.7 Empty states & copy — P1
Use warm, plain English with no emoji. Examples:
- **No junk:** "No junk found. Your library's already in good shape."
- **No trips yet:** "Your trips will appear here once we've scanned your library."
- **Everything curated:** "Every trip has an album. Nice work — 12.4 GB freed so far."
- **Back pocket empty:** "Nothing tucked away for this trip."
- Every delete-related screen repeats the trust line: items go to Recently Deleted and can be recovered for 30 days.

### 5.8 Settings — P2
- Background picker (`HanjiAppearanceSettings`).
- Autoplay interval.

## 6. Data mapping

`AlbumModel` / `AlbumSpread` / `AlbumPhoto` / `TripStamp` in `AlbumModels.swift` are view models, built from the existing trip/curation output:
- `AlbumPhoto.id` = `PHAsset.localIdentifier`, and `takenAt` = `creationDate`
- `keptCount` comes from the curated picks, and `totalCount` is all photos in the trip
- `bytesToFree` is the sum of the outtakes' resource sizes
- `miles` comes from the existing miles calculation
- Spreads come from `AlbumPaginator.spreads(...)`. Captions are the place name per day, or AI captions where they exist.

## 7. Setup tasks

- **Fonts:** the four files have been extracted to `photoapp/fonts/`: `Fraunces_72pt-Regular.ttf`, `Fraunces_72pt-SemiBold.ttf`, `DMMono-Regular.ttf`, `DMMono-Medium.ttf`.
  - Move them into a `Fonts` group inside `PhotoCurator/`, with target membership on, so they're listed under Copy Bundle Resources.
  - In Info.plist, add `ATSApplicationFontsPath` = `.`, or `Fonts` if they're copied into a `Fonts` subfolder of Resources.
  - Verify at launch in debug: `assert(NSFont(name: "Fraunces72pt-SemiBold", size: 12) != nil)`, and the same for the other three.
  - Don't bundle the variable Fraunces files or the zips.
- Set the deployment target to macOS 14 (needed for `onKeyPress`, `focusEffectDisabled`).
- Set the window min size to 1100×760 and the default to 1440×920.

## 8. Build phases

1. **Theme + shell:** add the theme (with the §4 font change and Korean-text removal), replace the sidebar with `HanjiShell`, remove the blue, and wire the existing views into the sections. *Done when:* the app runs with the new chrome and every old screen is reachable.
2. **Album book + trip workspace:** add the album files and build `AlbumModel` from a real trip. Add `TripRoute` / `TripWorkspaceView` (§3.1), and re-host the trip dashboard, tier review, day and extras views as Album mode, Curate mode, chapters / contact sheet and the Back pocket. *Done when:* swipe, keys, click, thumbnails, lightbox and autoplay all work, the tissue sweeps on every turn, and every §3.1 entry point lands in the right mode.
3. **Save & tidy:** implement §5.2 with a confirmation and celebration. *Done when:* outtakes appear in Recently Deleted and the album appears in Photos.
4. **Albums home + Review merge** (§5.3, §5.4).
5. **Map + Stamps restyle** (§5.5, §5.6).
6. **Polish:** VoiceOver pass, contrast check (4.5:1 text), Reduce Motion (make the tissue sweep a simple crossfade when `accessibilityReduceMotion` is on).

## 9. Success metrics

- Median clicks from launch to viewing a trip album ≤ 2.
- Share of detected trips curated within the first week ≥ 30%.
- GB freed per active user.
- Restore rate from Recently Deleted < 5%, a proxy for whether people trust the curation.

## 10. Out of scope (for now)

iOS app, sharing/export of albums as PDF, editing photos, cloud sync of curation state.
