# PhotoCurator

macOS app that curates a Photos library and drafts a chronological travel book.
Implements the PRD in `PRD AI Travel Photo Book and Library Curator (macOS).md`.

**Status: M1 (scanner prototype) complete.**

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

## What M1 does

M1 is **read-only**. It performs no deletion: there is no call to
`PHAssetChangeRequest.deleteAssets` anywhere in the codebase, so no code path
can remove a photo. Deletion arrives in M5, behind the one-button-per-tier
review screens.

The scan produces the dry-run report that PRD §4.4 and §12 specify:

- counts per tier, broken down by reason
- face clusters and how many people are "known"
- similarity clusters, including **how many extra clusters outfit splitting
  creates per day** (PRD §12 asks for this to judge the rule's accuracy)
- per-day photo and cluster counts, flagging days with no GPS
- the thresholds actually used, so the PRD §14 open questions can be tuned
  from real numbers

"Copy report" puts the whole thing on the clipboard as plain text.

## Layout

| Path | Contents |
| --- | --- |
| `PhotoCurator/Models` | `PhotoRecord`, tiers and reasons, all tunable thresholds |
| `PhotoCurator/Store` | SQLite analysis cache, PhotoKit read access |
| `PhotoCurator/Analysis` | quality signals, Vision requests, the scan driver |
| `PhotoCurator/Clustering` | face clustering, similarity clustering + outfit splitting |
| `PhotoCurator/Tiers` | tier assignment, best-photo scoring |
| `PhotoCurator/Report` | the M1 report model and its text rendering |
| `PhotoCurator/App` | SwiftUI scan, report and settings screens |

## Safety design

Two invariants are enforced in code and covered by tests:

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

M2 route map and day view · M3 Tier 1/2 preview grids · M4 face/outfit review
UI · M5 deletion with confirmations and logging · M6 personal taste model ·
M7 AI captions, book layout and PDF export.

The cache schema already carries the `deletion_log` and `confirmed_keep` tables
M5 needs, so adding deletion will not migrate an existing cache.
