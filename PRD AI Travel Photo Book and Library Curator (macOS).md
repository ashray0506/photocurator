# PRD: AI Travel Photo Book and Library Curator (macOS)

Version 1.0 · Target platform: MacBook (macOS 15+) · Intended reader: Claude / developer implementing the app

## 1. Overview

A native Mac app that scans a Photos library (about 10,000 photos), curates it, and drafts a chronological travel book in minutes. It does two jobs with one pipeline:

1. **Curate the library:** find duplicates, repetitive shots and junk, and delete them with one button per confidence tier instead of reviewing photos one by one.
2. **Draft the travel book:** organize the surviving photos by day, map the GPS route, add AI-written titles and captions, and export a print-ready PDF.

All processing runs on-device. Photos never leave the Mac except the text prompts sent to an AI model for captions (no image data unless the user opts in).

## 2. Goals and non-goals

**Goals**

- Reduce a 10k-photo library to a curated set with about 10 to 20 user decisions, not thousands.
- Produce a chronological book draft (one page per day plus route map) in under 5 minutes for 10k photos.
- Never lose a special photo: when unsure, keep.

**Non-goals (v1)**

- iOS or iPad app, cloud sync, collaboration.
- Direct ordering from a print service (PDF export only).
- Video curation.

## 3. Tech stack

- Swift 5.9+, SwiftUI, macOS 15+ deployment target.
- PhotoKit (PHAsset, PHAssetCollection, PHPhotoLibrary.performChanges) for read access, albums and deletion.
- Vision: VNGenerateImageFeaturePrintRequest (similarity), VNDetectFaceRectanglesRequest / VNDetectHumanRectanglesRequest (people), VNClassifyImageRequest (scene and junk classification), VNDetectFaceCaptureQualityRequest, and the aesthetics score request (CalculateImageAestheticsScoresRequest) on macOS 15+.
- Core Image / Accelerate for sharpness (Laplacian variance), exposure and color histograms.
- MapKit for the route map; PDFKit for export.
- SwiftData or SQLite for the analysis cache (so rescans are fast).
- AI captions: Anthropic API (text-only prompts) behind a protocol so the model can be swapped.

## 4. User flow

1. **Grant access:** request full Photos library access.
2. **Backup prompt:** recommend an external-drive backup before the first deletion; require a checkbox acknowledgement.
3. **Scan:** progress screen (analysis runs in the background, resumable, cached).
4. **Dry-run summary:** dashboard shows totals per tier, e.g. "Tier 1: 1,100 · Tier 2: 1,800 · Tier 3 protected: 3,200 · Remaining: 3,900". Nothing is changed yet.
5. **Tier review:** one screen per tier with a sample preview grid and **one button per tier** (see section 6).
6. **Draft book:** from the surviving photos, generate the chronological book and preview it.
7. **Export:** PDF.

## 5. Analysis pipeline

Run per photo, cache results keyed by asset local identifier plus modification date.

1. **Metadata:** capture date, GPS (lat/long), favorite flag, edited flag, album membership, media subtype (screenshot, burst, live photo).
2. **Quality signals:** sharpness, exposure (too dark or too bright), aesthetics score, lens-covered or pocket-shot detection (near-uniform image).
3. **Junk classification:** screenshots, receipts, documents, whiteboards, memes.
4. **People:** detect faces and bodies. Cluster faces library-wide. A face cluster is **known** if it appears in at least N photos (default 15) or spans at least 3 different days; otherwise **unfamiliar**. Photos where an unfamiliar face is the largest face in frame are "stranger-focused".
5. **Scene fingerprint:** Vision feature print per photo.
6. **Outfit fingerprint:** for each detected person, crop the torso region, compute a color histogram plus feature print. Used only for clustering (section 7), never for deletion by itself. Also used as a fallback to recognize a known person whose face is hidden.

## 6. Tiers and the one-button-per-tier review

Every photo is assigned exactly one tier. Tier 3 rules are checked first and always win.

### Tier 3: Protected (never touched)

- Favorites, photos in any user album, edited photos.
- Photos containing a known person.
- High-scoring no-face landscapes (aesthetics score at or above the "special" threshold, default top 15% of the library).
- **Button:** "Keep all" (confirms and locks them so they are excluded from future scans). No delete action exists for this tier.

### Tier 1: High confidence junk

- Exact duplicates and burst leftovers (best frame kept).
- Screenshots, receipts, documents.
- Extremely dark, blurry or accidental shots (pocket photos, lens covered).
- **Button:** "Delete Tier 1 (N photos)".

### Tier 2: Likely unwanted

- Near-duplicates (same scene, slightly different) beyond the per-cluster cap, with the best photos kept.
- No-face landscapes with low aesthetics score.
- Stranger-focused photos.
- **Button:** "Delete Tier 2 (N photos)".

### Review screen behavior (each tier)

- Header: count and estimated disk space freed.
- Preview grid: a random sample of 60 photos from the tier, tap to enlarge, tap to **rescue** an individual photo (moves it to Tier 3 for that photo only).
- A breakdown list by reason (e.g. "Duplicates 640, Blurry 210, Screenshots 250").
- One primary button. On press: show one confirmation sheet ("Delete N photos? They stay in Recently Deleted for 30 days"), then delete.
- Deletion uses PHPhotoLibrary.performChanges with PHAssetChangeRequest.deleteAssets in batches. macOS shows its own system confirmation; the app should explain this beforehand.
- After deletion, show an Undo hint pointing to Recently Deleted and log the deleted identifiers locally.

## 7. Clustering and duplicate rules

Build clusters over the non-protected photos, then keep the best photos per cluster.

**Combined similarity score** from four signals:

1. Time gap (primary)
2. GPS distance (primary)
3. Scene similarity (feature print distance)
4. Outfit similarity (tiebreaker only)

**Rules**

- Same day, same place, same scene, same outfit → retakes. Keep the best 1 to 2, mark the rest duplicates.
- Same day, same place, different outfit → different part of the day. Split into separate clusters and keep at least one from each.
- Cap per cluster: default 3 photos (configurable 1 to 5) so no moment dominates.
- Group shots: compare the best-matching person's outfit, not all people.
- Photos with no people ignore outfit and use scene, time and GPS only.
- Outfit can only **split** clusters. It must never be the sole reason for deleting a photo.

**Best-photo score** (higher is kept): aesthetics score, sharpness, exposure, eyes open and smiling (face capture quality), presence of known people (boost), composition.

## 8. Personal taste model (learns from favorites)

A small on-device classifier learns what this user likes and adjusts photo rankings. It is a scorer, not a decision-maker: it never overrides Tier 3 protections and never triggers deletion alone.

**How it works**

1. Convert every photo to an embedding using the Vision feature print (or a bundled CLIP model converted to Core ML).
2. Positive examples: favorites, photos in user albums, photos the user rescued during tier review, and photos swapped in as a cluster's pick.
3. Negative examples: photos the user confirmed deleting and the cluster alternatives the user swapped out.
4. Train a lightweight classifier (logistic regression or a small Core ML / Create ML layer) on the embeddings. Training runs on-device in seconds.
5. Output: a `tasteScore` from 0 to 1 per photo, stored on the PhotoRecord.

**Where tasteScore is used**

- Best-photo selection inside each cluster: final score = 0.6 x aesthetics and quality + 0.4 x tasteScore (weights configurable).
- Tier 2 ordering: within a tier, photos with higher tasteScore are shown last and are the first rescued if a cap applies.
- Book photo selection: ties between candidate photos are broken by tasteScore.

**Cold start and retraining**

- Requires at least 100 favorites and 100 negatives. Below that, tasteScore is disabled and the generic aesthetics score is used.
- Retrain after each tier review and each manual swap or rescue, and at most once per day otherwise.
- A Settings toggle turns the taste model off and a button resets it.

**Explanations (optional manager layer)**

Each kept or removed photo can show a one-line reason (for example "Kept: best of 6 similar shots, matches your favorite sunset style"). Reasons are generated from stored signals and scores, not from sending images to a model.

**Privacy:** embeddings, labels and the trained model never leave the Mac.

**Acceptance criteria**

- On a held-out 20% of the user's favorites, the model ranks a favorite above a random non-favorite at least 75% of the time (AUC at or above 0.75) before it is enabled.
- Disabling the model returns results identical to the generic scoring.

## 9. Safety requirements

1. Dry run first; no deletion before the summary is shown.
2. Conservative thresholds: when classification confidence is below the threshold, assign to Tier 3 or keep.
3. Backup reminder before the first deletion.
4. Recently Deleted (30 days) is the final safety net; the app never empties it.
5. Local deletion log with identifiers and reasons.
6. Thresholds adjustable in Settings with sensible defaults and a "Reset to defaults" option.

## 10. Travel book generation

1. Take the surviving photos (after tier deletion) and sort by timestamp.
2. Split into days, then into place segments by GPS clustering (about 500 m radius, 30 min gap).
3. Reverse-geocode each segment to a place name.
4. Choose the best 3 to 6 photos per day, spread across place segments.
5. Generate with the AI model: a day title (max 8 words) and a short caption per place segment, using date, place names and optional journal text as input.
6. Layout: one page per day with a title, 3 to 6 photos in a grid, captions, and a small MapKit snapshot of that day's route. A cover page and a full-trip route map as the first spread.
7. Support importing optional journal text per day (plain text or Markdown).
8. User can swap any chosen photo for another from the same cluster, and edit titles and captions inline.
9. Export to PDF with PDFKit at print resolution (300 dpi, bleed option).

## 11. Data model (suggested)

- **PhotoRecord:** id (PHAsset localIdentifier), date, lat, lon, isFavorite, isEdited, inAlbum, sharpness, exposure, aesthetics, junkType, featurePrint, faceClusterIds\[\], outfitPrint, tier, reason, clusterId, userOverride, tasteScore.
- **FaceCluster:** id, photoCount, dayCount, isKnown.
- **Cluster:** id, date, placeName, photoIds\[\], keptIds\[\].
- **Book:** days\[\] with title, caption, selectedPhotoIds\[\], routePoints\[\].

## 12. Milestones

1. **M1: Scanner prototype.** Import, cache, day grouping, and a read-only report of counts per tier and reason. No deletion. Include a report of how many extra clusters outfit splitting creates per day, to judge accuracy.
2. **M2: Route map and day view.**
3. **M3: Duplicate and quality curation** (Tier 1 and Tier 2 logic, preview grids).
4. **M4: Face and outfit rules** (known vs unfamiliar, protected set).
5. **M5: One-button tier review and deletion** with confirmations and logging.
6. **M6: Personal taste model** (train on favorites and review decisions, tasteScore in clustering and ranking, retraining, on/off toggle).
7. **M7: AI captions, book layout, PDF export.**

## 13. Acceptance criteria

- Scan of 10,000 photos completes in under 20 minutes on an Apple Silicon MacBook, and rescans in under 2 minutes using the cache.
- No photo in Tier 3 is ever deleted by any tier button.
- In a manual audit of a 200-photo sample from Tier 1, at least 98% are correctly junk or duplicate; for Tier 2, at least 90%.
- Each tier needs exactly one primary button press plus one confirmation to delete.
- Book draft for a 10k-photo library generates in under 5 minutes excluding caption API latency.
- PDF exports with correct day order and route maps.

## 14. Open questions

- Exact thresholds for "special landscape" and "known person" (start with defaults above, tune from M1 report).
- Whether captions should optionally use image content (requires sending images to the AI model) or stay text-only.
- Page size and print-service specifications for the PDF (A4, 8x10 in, square).
