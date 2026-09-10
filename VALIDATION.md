# PDFCopy validation — September 10, 2026

Tested two private, user-supplied PDFs entirely on-device. This public summary anonymizes the documents and omits source names, paths, identifiers, and extracted content. The originals were compared byte-for-byte before and after and were unchanged.

| Document | Pages | Added OCR tokens | OCR processing time | Region selection checks |
| --- | ---: | ---: | ---: | ---: |
| Document A (mixed text and scans) | 3 | 616 | 2.30 seconds | 614 / 614 |
| Document B (scanned form) | 5 | 480 | 2.62 seconds | 471 / 471 |

Timing covers page rendering for recognition, Vision OCR, and composing the text layer in the core pipeline. It excludes opening the app, refreshing its display document, and the independent QA image comparisons. These are individual local measurements, not a general performance guarantee.

## What passed

- All eight pages gained selectable text. All 1,085 tested OCR regions returned the recognized token when selected by its bounds. This is a selection/alignment test, not a measurement of recognition accuracy against a human transcript.
- The before/after renders were pixel-identical on all eight pages at the QA rendering resolution.
- Automated double-click simulations selected the entire OCR token in 1,057 of 1,085 cases. The remaining cases were compound or punctuated strings such as legal section references, hyphenated IDs, and slashes, for which native PDFKit selects a smaller word segment. Region selection recovered all tested tokens.
- A real UI test opened Document A, waited for OCR, double-clicked a heading, copied with Command-C, and pasted the correct text into a new TextEdit document.
- The complete automated suite passed: 10 tests, including real-document validation, real Vision OCR, mixed pages, no duplicate native text, crop/rotation geometry, page appearance, close word spacing, background document updates, selection deferral, and accessibility traversal.

## Bugs found and fixed

1. Document A's first page has an unusable embedded font mapping: PDFKit initially extracts repeated `ÿ` characters. Geometric overlap alone incorrectly suppressed useful OCR. Duplicate detection now checks both location and matching characters. The complete printed heading and body paragraph are selectable after OCR.
2. Tightly positioned OCR words could lose their separating space when copied. The invisible layer now contains explicit word separators.
3. Temporary OCR document ownership could leave PDFKit with invalid page references and crash accessibility inspection. OCR documents remain alive until a fresh display document is composed; the app does not mutate the document currently being displayed.

## Remaining quality gaps

- Vision misses several isolated paragraph numbers on Document A's second page, including 1, 2, 4, 5, and 7 in this run.
- Handwriting and the overlapping signature/printed-name area on Document A's third page are not accurately transcribed. Short identifiers also contain occasional letter/digit substitutions.
- Whole-page extraction interleaves a stamp with a heading. Some form label/value pairs and multi-line table rows have imperfect reading order. Selecting a specific word or region remains the better-tested path.
- Decorative symbols can be recognized as text, including progress circles and an external-link icon. There are occasional ordinary word/character errors.
- The black redaction on Document B remained black in the rendered comparisons and contributed no recovered value in the OCR output. This was a rendering/OCR check, not a forensic redaction audit.
- Large-document memory/performance, additional languages, unusual page layouts, annotations/forms, and offline startup on a clean machine still require validation. The app is a locally signed prototype, not a notarized release.

## Reproduce

```sh
PDFCOPY_TEST_DOCUMENTS='/absolute/path/to/pdf/folder' \
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox
```

Private extracted text, rendered comparison images, and raw metrics stay in `.build/validation/`, which is ignored by version control. No source PDFs or extracted private content are embedded in the test source.

The next engine decision should compare Vision with another fully local engine on these specific failures. MinerU has not yet been benchmarked or installed.

## Scrolling regression

A follow-up test reproduced repeated document reloads during scrolling on a three-page synthetic scan. The previous build assigned the display document four times (initial open plus three OCR updates) and changed the scroll position. The fix batches short-document OCR results, defers updates during live scrolling and text selection, waits for viewport activity to settle, and restores the exact scroll origin and scale in a single layout update. Larger documents schedule an update after eight ready pages.

The same regression fails against the previous source and passes against the corrected source: one initial document assignment, no reload during scrolling, then one OCR refresh after scrolling ends. All three pages retain recognized text, and zoom and scroll position stay unchanged.

## Search and iOS (0.2.0)

The Mac suite passes 12 synthetic tests with no failures; the opt-in private-document test is skipped in the default run. Search tests cover case-insensitive results across pages, next/previous wraparound, no matches, clearing, rapid query cancellation, document replacement, OCR result updates, and keeping the user's copy selection intact. The existing OCR and scrolling regressions continue to pass.

A live Mac check on Document B found eight matches for a test query and advanced the counter with Command-G. No private contents or screenshots were added to the repository. OCR refreshes also preserve the active Mac search-field responder.

Three iOS integration tests passed on an iPhone 17 Pro simulator (iOS 26.3.1), an iPad mini simulator (iOS 26.5), and an iPhone 15 Pro simulator (iOS 17.2). These exercise shared search plus a three-page synthetic scan through actual Vision OCR, deferred refresh during scrolling, preserved scale/offset, and copying recognized text to the iOS pasteboard. An unsigned physical-device build also succeeded. Simulator UI inspection stalled, so these results do not establish end-to-end touch-gesture or Files/share-menu usability. Physical-device installation, touch selection, background transitions, memory pressure, and large-document performance remain to be checked before release.

Search uses temporary PDFView highlights, not document annotations. It matches within a page's extracted string; line-break/layout differences and phrases spanning page boundaries can prevent a match. Results expand when recognized text reaches the displayed document. Search does not require an account or network service.

## Stale scanner OCR (0.2.1)

A two-page private card scan contained corrupt invisible text from the scanner, even though the visible lettering was readable and Vision recognized it correctly. Adding new OCR on top retained competing bad text at the same positions. The repair detects image pages whose text-showing operators are exclusively invisible, checks OCR coverage and confidence, and replaces the old layer when the new OCR conflicts. Unknown nested forms and visible-text pages are excluded from automatic rebuilding. Graphics-state save/restore is tracked while examining text rendering modes.

The private scan was inspected locally before and after repair; the name-region selection now contains the correctly recognized characters without the stale scanner spelling. PDFKit can expand word selection to a whole nearby name/label line; selection handles still control the exact copied range. The in-memory rebuilt background was visually checked. The original PDF was not modified, and no private text, images, file paths, or document metadata are included in these tests or this summary.

Six synthetic regression tests cover stale hidden OCR replacement, accurate hidden OCR preservation, visible-text protection, low coverage/confidence protection, small-page raster resolution, and actual Vision recognition on a synthetic card. All 18 default Mac tests pass; the separate private-document test remains opt-in.

All nine iOS integration tests pass on the iPhone simulator. The earlier private eight-page test set also passes, with no measured changes to page appearance at the test render resolution. Signed iPhone and packaged Mac builds succeed.
