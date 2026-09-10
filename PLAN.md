# PDFCopy plan

## Product decisions

- macOS first; iOS follows using the shared recognition core.
- Primary path: open a PDF → double-click or drag over text → Command-C → paste in another app.
- Support PDFs with embedded text, image-only scans, and mixed pages.
- All document processing stays on-device. No accounts, uploads, analytics, remote OCR, or model API calls.
- No editing or annotation tools. Search and image copying are phase 2. PDF questions come later and must remain local.

## Phase 1: Mac prototype

Use SwiftUI for the shell, PDFKit for display and native selection, and Vision accurate text recognition for OCR. Vision is the initial engine because it integrates into both Apple platforms without packaging a separate Python/model service. MinerU remains a candidate to benchmark, not a claimed inferior engine. Its focus is structured document extraction; the immediate product needs accurate word positions and low-friction selection.

1. Open via file picker, Finder Open With, drop, or command line. Prompt for protected-document passwords and honor copy permissions.
2. Display the PDF immediately; existing text remains selectable during OCR.
3. Process visible-page-first on a background actor, then nearby pages; permit pausing.
4. Render each page through its crop/rotation transform and recognize text with word positions.
5. Create an in-memory derivative page retaining original content plus invisible text for missing words. Avoid duplicate text in regions with an existing text layer. Never save over the source.
6. Batch page replacement and defer it during live scrolling or active text selection; preserve the viewport and zoom. Provide a manual full-page OCR rebuild for bad embedded text.
7. Verify real OCR, native-text retention, mixed pages, crop/rotation, and selection at recognized coordinates. Package a runnable local app.

## Phase 1 validation before calling it production-ready

The engine choice remains provisional until tested against representative user PDFs. Evaluate ordinary scans, photographs, skew, low contrast, multiple columns, tables, small type, unusual fonts, and required languages. Measure copied-text error rate, time until the visible page is selectable, text/highlight alignment, reading order, and peak memory on long files. Include an offline launch/run check on a clean machine.

The prototype uses Vision language autodetection and its installed supported languages. It cannot promise recognition of every language, handwriting style, equation, or illegible scan. Complex column/table reading order needs explicit validation. The app currently holds documents in memory, recomputes OCR on reopening, and does not have a persistent OCR cache. It serializes a fresh display document for each batch to keep PDFKit page ownership and accessibility references valid; larger-document performance still needs measurement. Existing annotations/forms and navigation links also need preservation testing when OCR replaces a page. Add bounded caching, large-document stress tests, per-page OCR diagnostics, accessibility and keyboard QA, and a signed/notarized release before distribution.

## Phase 2

- Search across embedded and recognized text, with navigation and highlights.
- Copy page image regions to the clipboard using a simple selection gesture.
- Improve layout handling and OCR engine selection based on measured failures.

## iOS

Reuse `PDFCopyCore`; build the document-picker/share-sheet and UIKit PDFView integration. Validate touch selection, Copy menu, memory pressure, background cancellation, and phone/iPad layouts. The Mac shell is not an iOS app yet.

## Later: local PDF questions

Use extracted text with page citations and an on-device model. Select a model only after measuring supported hardware, download/storage requirements, answer quality, and latency. Never silently fall back to a cloud provider.

## References

- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Apple PDFView](https://developer.apple.com/documentation/pdfkit/pdfview)
- [MinerU](https://github.com/opendatalab/MinerU)
