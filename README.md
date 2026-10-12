# PhotoCurator

macOS app that curates a Photos library and drafts a chronological travel book.
Implements the PRD in `PRD AI Travel Photo Book and Library Curator (macOS).md`.

**Status: M1 (scanner prototype) + M3 preview grids + M5 deletion complete.**

## Requirements

- macOS 15+
- Xcode 16+ (the project targets Swift 6 with strict concurrency)

## Build and run

```sh
open PhotoCurator.xcodeproj
```

Then ⌘R to run, ⌘U to test. On first run macOS asks for Photos access;
PhotoCurator requests full library access because duplicate detection has to
compare across the whole library.

## What's implemented

The scan produces the dry-run report that PRD §4.4 and §12 specify:

- counts per tier, broken down by reason
- face clusters and how many people are "known"
- similarity clusters, including **how many extra clusters outfit splitting
  creates per day** (PRD §12 asks for this to judge the rule's accuracy)
- per-day photo and cluster counts, flagging days with no GPS
- the thresholds actually used, so the PRD §14 open questions can be tuned
  from real numbers

"Copy report" puts the whole thing on the clipboard as plain text.

Tapping a tier in the report opens its review screen (PRD §6):

- header with count and estimated disk space freed
- a 60-photo random sample grid, tap to enlarge, tap to rescue into Tier 3
- a reason breakdown
- **Tier 3**: "Keep all" only — there is no delete action anywhere on this
  tier's screen.
- **Tier 1 / Tier 2**: "Delete Tier N (count)" → one confirmation sheet
  ("stay in Recently Deleted for 30 days") → batched
  `PHAssetChangeRequest.deleteAssets` calls, with progress shown for large
  batches. macOS shows its own system confirmation on top of this app's.

## Layout

| Path | Contents |
| --- | --- |
| `PhotoCurator/Models` | `PhotoRecord`, tiers and reasons, all tunable thresholds |
| `PhotoCurator/Store` | SQLite analysis cache, PhotoKit read access, thumbnail loading |
| `PhotoCurator/Analysis` | quality signals, Vision requests, the scan driver |
| `PhotoCurator/Clustering` | face clustering, similarity clustering + outfit splitting |
| `PhotoCurator/Tiers` | tier assignment, best-photo scoring, the deletion service |
| `PhotoCurator/Report` | the scan report model and its text rendering |
| `PhotoCurator/App` | SwiftUI scan, report, tier review and settings screens |

## Safety design

Three invariants are enforced in code and covered by tests:

1. **Tier 3 always wins.** Protection is evaluated before any junk rule, so a
   favorite, album member, edited photo, photo containing a known person, or a
   rescued photo can never fall through into a deletable tier
   (`TierAssignerTests.testNoProtectedPhotoEverLeavesTier3` sweeps signal
   combinations to assert this).
2. **Unmeasured is not zero.** Pixel signals on `QualitySignals` are optional.
   A photo whose pixels could not be decoded has `nil` sharpness, not `0`, so
   it is never mistaken for a dark, blurry, flat frame and deleted. Tier rules
   treat `nil` as "no evidence of junk", per PRD §9.2 ("when unsure, keep").
   Ranking uses neutral stand-ins so such a photo sits mid-pack instead.
3. **Deletion has two independent guards.** `TierAssigner` never assigns
   Tier 3 to anything a delete button touches, and `PhotoDeletionService`
   separately refuses, at the call site, to delete any record whose tier is
   `.tier3Protected` — a caller passing the wrong set throws instead of
   deleting (`PhotoDeletionServiceTests`). The deletion log is written
   *before* the PhotoKit call, so a crash mid-batch still records what was
   requested (PRD §9.5).

Metadata-certain junk (a screenshot subtype) is still caught without pixel
analysis, so the uncertainty guard runs after those checks, not before.

## Performance notes

Against the PRD §13 budgets:

- Analysis is bounded-concurrency (cores − 1), not an unbounded task group, so
  10k photos do not sit decoded in memory at once.
- Images are decoded once at 512px via `requestImageDataAndOrientation`.
  (`PHImageManager.requestImage` is unavailable on macOS — its result handler
  returns an `NSImage` that Swift cannot import from the Photos headers.)
- Results are cached in SQLite keyed by local identifier + modification date,
  and written in batches of 250, so a cancelled scan keeps its progress and a
  rescan only re-analyses changed photos.
- Face clustering matches against cluster exemplars rather than all pairs,
  which would be ~50M comparisons at this library size.

## Not yet built

M2 route map and day view · M4 face/outfit review UI (clustering itself exists;
there's no dedicated screen to inspect/correct face clusters yet) · M6
personal taste model · M7 AI captions, book layout and PDF export.

## Known limitation at large libraries

The full pipeline (metadata → quality → junk → faces → clustering → tiers)
was validated against the PRD's ~10k-photo target. At 50k+ photos a single
scan session takes proportionally longer; the SQLite cache and bounded
concurrency should still hold, but this has not yet been measured against
the PRD §13 budget at that scale. If a scan at this size needs to be run in
multiple sittings, the cache's resumability (batched writes every 250 photos)
means progress is not lost — stopping and relaunching picks up from the cache
rather than re-analysing from scratch.
