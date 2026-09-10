# PDFCopy

<img src="Assets/AppIcon.png" width="128" height="128" alt="PDFCopy app icon: a paper page with highlighted text on a blue tile">

A native macOS and iOS prototype for opening PDFs, selecting text, and copying it elsewhere. OCR runs locally with Apple Vision. SwiftUI and PDFKit provide the interface and native text selection.

## Run

Requires macOS 14+ and Xcode with Swift 5.9+.

```sh
git clone https://github.com/jasontitus/pdfcopy.git
cd pdfcopy
bash scripts/build-app.sh
open dist/PDFCopy.app
```

Or open `Package.swift` in Xcode and run the PDFCopy executable scheme. `swift run PDFCopy /absolute/path/to/document.pdf` also works.

Open or drop a PDF. Existing text is selectable immediately. OCR adds selectable text to scans and image regions in the background, starting with the visible page. Double-click a word, drag a selection, then press Command-C or use the Copy button. Use **Recognize Again** on a page whose embedded text copies incorrectly. Recognition never overwrites your PDF. Completed recognition is remembered in a bounded local cache for fast reopening; you can disable or clear it in Saved Text Settings.

The local app bundle is ad-hoc signed for development, not notarized for distribution. It contains no third-party dependencies or network code. Text copied to the system clipboard is handled by macOS and the user's clipboard settings.

OCR display updates are batched and wait until scrolling and text selection have stopped. Short documents refresh once after recognition; longer documents schedule updates after eight ready pages. The viewport and zoom are preserved during each refresh.

This is an early prototype for Mac, iPhone, and iPad. Read the [privacy notes](PRIVACY.md), [roadmap](PLAN.md), and [known limitations](VALIDATION.md) before testing important documents.

## Install on your Mac

1. Build the app using the commands above. Xcode is needed to build; it is not needed just to run an already-built app.
2. Quit PDFCopy if it is running.
3. In Finder, open the project's `dist` folder and drag **PDFCopy.app** into **Applications**. If updating, replace the previous copy when prompted.
4. Launch **PDFCopy** from Applications or Spotlight. Open a PDF with **Command-O**, select text, and press **Command-C** to copy it.

The bundle includes its app icon and runs on macOS 14 or later. The build script produces a local, ad-hoc-signed app for the build machine's architecture; this is not a notarized download or a universal Mac release. Future updates currently require rebuilding and replacing the app.

The icon's source artwork and generation prompt are described in [Assets/README.md](Assets/README.md). The build generates all macOS icon sizes automatically with the system's `sips` and `iconutil` tools.

## Reading tools (0.3.0)

- **Page readiness:** the banner above the PDF shows whether the visible page is ready, recognizing, or waiting to apply improved text. Choose **Use improved text** to clear the current selection and apply pending OCR safely.
- **Precise word selection on iPhone/iPad:** tap a word to select its explicit character range instead of relying on PDFKit's broader word/phrase selection. Hold and drag remains available for larger selections. The footer previews selected text beside Copy.
- **Focused OCR:** choose **Recognize Area…** from Recognize (Mac) or More (iOS), then drag around text inside one page. **Recognize Selection** uses the current single-page selection. A higher-resolution, on-device OCR pass opens a read-only text preview with Copy All and individual word buttons. It does not rewrite the PDF or save that region result in the cache.
- **Saved text:** use the drive icon on Mac or **More → Saved Text Settings** on iOS. Completed OCR copies are stored only on this device, keyed by PDF contents and engine/OS version. The cache is limited to 256 MB / 20 files, expires entries after 30 days without access, and is excluded from backups. iOS files use complete file protection; local files use owner-only permissions. Password-protected PDFs are never cached. Disabling caching clears existing saved copies; clearing also blocks in-flight work from recreating them during the current open session. Originals stay unchanged.

## Search

On Mac, press **Command-F** or click Search. Type a word or phrase to highlight matches, then use the arrows, **Command-G**, or **Shift-Command-G** to navigate. On iPhone/iPad, tap the magnifying glass. Search ignores case and accents and updates as OCR finishes. It searches text within each page; phrases spanning page breaks and text split by layout/line breaks may not match. Search highlights do not change the text selected for copying or create PDF annotations.

## Install on iPhone or iPad

Requires iOS/iPadOS 17+ and Xcode with the iOS SDK.

1. Open **PDFCopy.xcodeproj** in Xcode and select the **PDFCopyIOS** scheme.
2. Select the **PDFCopyIOS** target, open **Signing & Capabilities**, and choose your development team (also set it on the test target if running tests on a device). Use a unique bundle identifier if Xcode requests one. Signing credentials are not included in this repository.
3. Connect your iPhone/iPad, select it as the run destination, and enable Developer Mode on the device if prompted.
4. Click **Run**. Once installed, open PDFCopy and tap the folder to choose a PDF from Files. You can also use a PDF's Share menu and choose PDFCopy when offered.
5. Tap a word to select it precisely, or touch and hold and adjust the selection handles to select more, then use **Copy**. Pinch to zoom; tap Search to find text.

This is a development install, not an App Store or TestFlight release. Real-device signing requires your Apple development account; simulator builds do not. Recognition pauses when the app enters the background and resumes when it becomes active. A Files provider may download the original PDF (for example from iCloud); OCR and search themselves run locally.

For a simulator build from Terminal:

```sh
bash scripts/build-ios.sh
```

The output is `.build/ios/Build/Products/Debug-iphonesimulator/PDFCopy.app`. To run iOS integration tests, choose a simulator in Xcode and press **Command-U**, or:

```sh
xcodebuild -project PDFCopy.xcodeproj -scheme PDFCopyIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO test
```

Use a simulator name installed on your Mac. The checked-in Xcode project needs no generator to build. If changing targets or file lists, edit `project.yml` and run `xcodegen generate` (XcodeGen is a development-only tool).

## Try a synthetic sample

After building the app, generate a three-page sample containing native text, scanned text, and mixed content:

```sh
swift scripts/make-sample.swift
open -a "$PWD/dist/PDFCopy.app" "$PWD/dist/Sample.pdf"
```

No real documents are bundled in this repository.

## Test

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox
```

Tests exercise actual Vision OCR on generated scans, mixed native/scanned content, duplicate suppression, invisible-text selection, unchanged page appearance, rotated/cropped geometry, and forced text replacement. An app-level regression test covers background OCR, live document refresh, deferred updates during selection, and accessibility traversal. See [PLAN.md](PLAN.md) for scope, later phases, and remaining release validation.

## Structure

- `PDFCopyCore`: render/recognize/compose pipeline and replaceable `TextRecognizer` interface.
- `PDFCopy`: Mac interface plus shared document scheduling and search.
- `iOS/PDFCopy`: iPhone/iPad interface, Files picker, native PDF view, and icon.
- `PDFCopy.xcodeproj`: iOS app and tests; generated from `project.yml` using XcodeGen.
- `Tests`: generated PDF fixtures and OCR/selection integration tests.

The initial OCR engine has been evaluated on eight pages from two user-supplied PDFs; see `VALIDATION.md`. It has not been benchmarked against MinerU. Isolated list numbers, handwriting, complex reading order, and languages outside Vision's support need further work. Image copying and local PDF questions are not implemented yet.

To run the optional real-document tests, set `PDFCOPY_TEST_DOCUMENTS` to a local folder when running `swift test`. Rendered comparisons, extracted text, and metrics stay under the ignored `.build/validation` directory; private document contents are not included in the source tree.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and bug-report guidance.

Scanner-generated PDFs sometimes contain incorrect invisible OCR text. When a page contains images and exclusively invisible text, PDFCopy can rebuild that text layer if fresh, confident OCR conflicts with it and recognizes enough of the original content. This uses a rendered background in the in-memory copy; the source PDF stays unchanged. Mixed/visible-text pages and uninspected nested content keep their original text; **Recognize Again** remains available. Small card-sized scans now render at a minimum 1600-pixel longest edge (within the existing 16-megapixel limit).
