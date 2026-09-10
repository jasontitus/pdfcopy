#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit
import PDFCopyCore
import SwiftUI
import QuartzCore

actor OCRWorker {
    private let document: PDFDocument?
    init(data: Data, password: String?) {
        document = PDFDocument(data: data)
        if let password { _ = document?.unlock(withPassword: password) }
    }
    func process(index: Int, replace: Bool) throws -> PageRecognitionResult {
        try Task.checkCancellation()
        guard let page = document?.page(at: index) else { throw RecognitionError.invalidPage }
        return try PageRecognizer.process(page, replaceExistingText: replace)
    }
}

actor RegionWorker {
    func recognize(data: Data, region: CGRect) throws -> String {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { throw RecognitionError.invalidPage }
        return try RegionRecognizer.text(from: RegionRecognizer.recognize(page, region: region))
    }
}

@MainActor
final class DocumentModel: ObservableObject {
    @Published var document: PDFDocument?
    @Published var fileName = "PDFCopy"
    @Published var currentPage = 0
    @Published var processed = 0
    @Published var running = false
    @Published var status = "Open a PDF to get started"
    @Published var error: String?
    @Published var password = ""
    @Published var needsPassword = false
    @Published var hasSelection = false
    @Published var failedPages: Set<Int> = []
    @Published private(set) var readyPages: Set<Int> = []
    @Published private(set) var waitingPages: Set<Int> = []
    @Published var selectingRegion = false
    @Published var showsRegionResult = false
    @Published private(set) var recognizingRegion = false
    @Published private(set) var regionText = ""
    @Published private(set) var regionMessage = ""
    @Published var showsCacheSettings = false
    @Published private(set) var remembersOCR: Bool
    @Published private(set) var cacheMessage = ""
    @Published private(set) var cacheBytes = 0
    @Published private(set) var openingCache = false
    let search = PDFSearchModel()
    @Published var showsSearch = false
    weak var pdfView: PDFView?
    private let cache: OCRCache?
    private let defaults: UserDefaults
    private var cacheLookup: OCRCache.Lookup?
    private var cacheOpening: Task<Void, Never>?
    private var cacheWriting: Task<Void, Never>?
    private var cacheAllowed = false
    private var cachedDocument: PDFDocument?
    private var regionJob: Task<Void, Never>?
    private var regionGeneration = UUID()
    private let regionWorker = RegionWorker()
    private var sourceData: Data?
    private var worker: OCRWorker?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var pending: Set<Int> = []
    // Keep the owning documents alive until composition; PDFPage alone is not enough.
    private var replacements: [Int: PDFDocument] = [:]
    private var forced: Set<Int> = []
    private var completed: Set<Int> = []
    private var activeRequest: (index: Int, replace: Bool)?
    private var displayUpdate: Task<Void, Never>?
    private var liveScrolling = false
    private var lastViewportActivity = -Double.infinity
    private var applyingPages = false
    private let updateBatchSize = 8

    init(cache: OCRCache? = .shared, defaults: UserDefaults = .standard) {
        self.cache = cache; self.defaults = defaults
        self.remembersOCR = defaults.object(forKey: "rememberOCR") as? Bool ?? true
    }

    var pageReadiness: String {
        guard pageCount > 0, !needsPassword else { return "" }
        let number = currentPage + 1
        if failedPages.contains(currentPage) { return "Page \(number): recognition failed · try an area" }
        if waitingPages.contains(currentPage) {
            return hasSelection ? "Page \(number): improved text waiting · clear selection to apply"
                : "Page \(number): text recognized · applying when scrolling stops"
        }
        if readyPages.contains(currentPage) { return "Page \(number) ready to select and copy" }
        if openingCache { return "Checking saved text for this PDF…" }
        return "Page \(number): \(running ? "recognizing text…" : "recognition paused")"
    }
    var canApplyText: Bool { hasSelection && !waitingPages.isEmpty }
    private var hasReadyUpdates: Bool { !replacements.isEmpty || cachedDocument != nil }

    private var readyMessage: String {
        #if os(macOS)
        return "Ready · double-click a word or drag to select text"
        #else
        return "Ready · tap a word, or hold and drag to select more"
        #endif
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    #if os(macOS)
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    #endif

    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let pdf = PDFDocument(data: data), pdf.isLocked || pdf.pageCount > 0 else {
                error = "This file is not a readable PDF."; return
            }
            job?.cancel()
            cacheOpening?.cancel(); cacheWriting?.cancel(); regionJob?.cancel()
            cacheLookup = nil; cachedDocument = nil; openingCache = false
            cacheAllowed = false; readyPages = []; waitingPages = []
            selectingRegion = false; showsRegionResult = false; recognizingRegion = false
            regionText = ""; regionGeneration = UUID()
            displayUpdate?.cancel()
            generation = UUID()
            liveScrolling = false; lastViewportActivity = -Double.infinity
            worker = nil
            pending = []; replacements = [:]; forced = []; completed = []; failedPages = []; activeRequest = nil
            processed = 0; currentPage = 0; hasSelection = false; running = false
            search.reset()
            sourceData = data; document = pdf; fileName = url.lastPathComponent
            password = ""
            needsPassword = pdf.isLocked
            if needsPassword { status = "Enter the PDF password to open it" }
            else { startRecognition(password: nil) }
        } catch { self.error = "Could not open PDF: \(error.localizedDescription)" }
    }

    func unlock() {
        guard let document, document.unlock(withPassword: password) else {
            error = "That password did not unlock the PDF."; return
        }
        needsPassword = false
        startRecognition(password: password)
        password = ""
    }

    private func startRecognition(password: String?) {
        guard let sourceData, let document else { return }
        guard document.allowsCopying else {
            status = "This PDF does not permit copying text."; return
        }
        worker = OCRWorker(data: sourceData, password: password)
        pending = Set(0..<document.pageCount)
        remembersOCR = defaults.object(forKey: "rememberOCR") as? Bool ?? true
        cacheAllowed = remembersOCR && !document.isEncrypted && password == nil && cache != nil
        guard cacheAllowed, let cache else { runQueue(); return }
        openingCache = true
        status = "Checking saved OCR · on this device"
        let token = generation
        cacheOpening = Task { [weak self] in
            let lookup = await cache.lookup(source: sourceData)
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.openingCache = false
            guard self.cacheAllowed else { self.runQueue(); return }
            self.cacheLookup = lookup
            if let data = lookup.data, let cached = PDFDocument(data: data), !cached.isLocked,
               cached.pageCount == self.pageCount {
                self.cachedDocument = cached
                self.completed = Set(0..<cached.pageCount); self.pending = []
                self.processed = cached.pageCount; self.waitingPages = self.completed
                self.status = "Saved OCR loaded · applying when the page is idle"
                self.scheduleDisplayUpdate()
            } else { self.runQueue() }
        }
    }

    func retryPage() {
        guard worker != nil, pageCount > 0, !openingCache else { return }
        readyPages.remove(currentPage)
        forced.insert(currentPage); pending.insert(currentPage)
        if !running { runQueue() }
    }

    func toggleProcessing() {
        if running {
            if let request = activeRequest, request.replace { forced.insert(request.index) }
            job?.cancel(); generation = UUID(); running = false
            status = "Recognition paused · existing text is still selectable"
            scheduleDisplayUpdate()
        } else if !pending.isEmpty { runQueue() }
    }

    private func runQueue() {
        guard let worker else { return }
        running = true
        let token = generation
        job = Task { [weak self] in
            while let self, !Task.isCancelled, self.generation == token, !self.pending.isEmpty {
                // The visible page and then its neighbors get processed first.
                let index = self.pending.min { abs($0 - self.currentPage) < abs($1 - self.currentPage) }!
                let replace = self.forced.remove(index) != nil
                self.activeRequest = (index, replace)
                self.status = "Recognizing page \(index + 1) of \(self.pageCount) · on this device"
                do {
                    let result = try await worker.process(index: index, replace: replace)
                    guard !Task.isCancelled, self.generation == token else { return }
                    if let data = result.pdfData, let replacement = PDFDocument(data: data) {
                        self.replacements[index] = replacement
                        self.waitingPages.insert(index); self.readyPages.remove(index)
                        if self.replacements.count >= self.updateBatchSize { self.scheduleDisplayUpdate() }
                    }
                    if result.pdfData == nil { self.readyPages.insert(index) }
                    self.failedPages.remove(index)
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.failedPages.insert(index)
                }
                // A forced retry requested during this pass must remain queued.
                if !self.forced.contains(index) { self.pending.remove(index) }
                self.completed.insert(index)
                self.processed = self.completed.count
                self.activeRequest = nil
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.running = false
            self.status = self.failedPages.isEmpty
                ? (self.replacements.isEmpty ? self.readyMessage
                    : "Text recognized · finishing when the page is idle")
                : "Recognition failed on \(self.failedPages.count) page(s) · use Recognize Again to retry"
            self.scheduleDisplayUpdate()
            self.saveCompletedOCR()
        }
    }

    func selectionChanged() {
        hasSelection = !(pdfView?.currentSelection?.string?.isEmpty ?? true)
        if hasSelection && hasReadyUpdates { status = "Improved text is ready · clear your selection to apply it" }
        if !hasSelection { scheduleDisplayUpdate() }
    }

    func scrollActivity(began: Bool = false, ended: Bool = false) {
        guard !applyingPages else { return }
        if began { liveScrolling = true }
        if ended { liveScrolling = false }
        lastViewportActivity = ProcessInfo.processInfo.systemUptime
        displayUpdate?.cancel()
        if !liveScrolling { scheduleDisplayUpdate() }
    }

    private func scheduleDisplayUpdate() {
        displayUpdate?.cancel()
        guard !liveScrolling, !hasSelection, !selectingRegion, hasReadyUpdates,
              !running || replacements.count >= updateBatchSize else { return }
        let token = generation
        let delay = max(0.15, 0.5 - (ProcessInfo.processInfo.systemUptime - lastViewportActivity))
        displayUpdate = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.applyReadyPages()
        }
    }

    private func applyReadyPages() {
        #if os(iOS)
        if let scroll = pdfView?.contentScrollView,
           scroll.isTracking || scroll.isDragging || scroll.isDecelerating || scroll.isZooming {
            scrollActivity()
            return
        }
        #endif
        guard let document, let view = pdfView,
              !liveScrolling, !selectingRegion, ProcessInfo.processInfo.systemUptime - lastViewportActivity >= 0.5,
              view.currentSelection?.string?.isEmpty ?? true, hasReadyUpdates else { return }
        let oldPage = view.currentPage.map { document.index(for: $0) }.flatMap { $0 == NSNotFound ? nil : $0 } ?? currentPage
        let point = view.currentDestination?.point ?? .zero
        let scale = view.scaleFactor
        #if os(macOS)
        let responder = view.window?.firstResponder
        let scrollOrigin = view.documentView?.enclosingScrollView?.contentView.bounds.origin
        #else
        let scrollOrigin = view.contentScrollView?.contentOffset
        #endif
        // Do not mutate PDFView's live document. Its accessibility tree retains page
        // references; moving pages between documents can leave stale CoreGraphics roots.
        let refreshed: PDFDocument
        if let cachedDocument { refreshed = cachedDocument }
        else {
            let staging = PDFDocument()
            for index in 0..<document.pageCount {
                guard let page = replacements[index]?.page(at: 0) ?? document.page(at: index),
                      let copy = page.copy() as? PDFPage else { return }
                staging.insert(copy, at: index)
            }
            guard let data = staging.dataRepresentation(), let composed = PDFDocument(data: data) else {
                error = "Could not update the PDF with recognized text."; return
            }
            refreshed = composed
        }
        applyingPages = true
        defer { applyingPages = false }
        // Present document, scale, and scroll restoration in a single screen update.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if os(macOS)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            self.document = refreshed
            view.document = refreshed
            view.scaleFactor = scale
            view.layoutDocumentView()
            if let origin = scrollOrigin, let scroll = view.documentView?.enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if let page = refreshed.page(at: min(oldPage, refreshed.pageCount - 1)) {
                view.go(to: PDFDestination(page: page, at: point))
            }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if let responder { view.window?.makeFirstResponder(responder) }
        }
        #else
        UIView.performWithoutAnimation {
            self.document = refreshed
            view.document = refreshed
            view.scaleFactor = scale
            view.layoutDocumentView()
            view.layoutIfNeeded()
            if let origin = scrollOrigin, let scroll = view.contentScrollView {
                scroll.setContentOffset(origin, animated: false)
            } else if let page = refreshed.page(at: min(oldPage, refreshed.pageCount - 1)) {
                view.go(to: PDFDestination(page: page, at: point))
            }
        }
        #endif
        CATransaction.commit()
        search.attach(document: refreshed, view: view)
        readyPages.formUnion(waitingPages); waitingPages = []
        replacements.removeAll(); cachedDocument = nil
        saveCompletedOCR()
        if !running, failedPages.isEmpty {
            status = pending.isEmpty ? readyMessage
                : "Recognition paused · existing text is still selectable"
        }
    }

    func attach(_ view: PDFView) {
        pdfView = view
        scheduleDisplayUpdate()
    }

    func applyImprovedText() {
        pdfView?.clearSelection(); hasSelection = false
        scheduleDisplayUpdate()
    }

    private func saveCompletedOCR() {
        guard cacheAllowed, remembersOCR, !running, pending.isEmpty, failedPages.isEmpty,
              !hasReadyUpdates, processed == pageCount, pageCount > 0,
              let cache, let lookup = cacheLookup, let data = document?.dataRepresentation() else { return }
        cacheWriting?.cancel()
        cacheWriting = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await cache.store(data, for: lookup) }
            catch { self?.cacheMessage = "Could not save OCR; the PDF is still available." }
        }
    }
    func refreshCacheSize() {
        guard let cache else { return }
        Task { cacheBytes = await cache.size() }
    }
    func setRemembersOCR(_ enabled: Bool) {
        remembersOCR = enabled; defaults.set(enabled, forKey: "rememberOCR")
        if !enabled { clearCachedOCR() }
    }
    func clearCachedOCR() {
        cacheAllowed = false; cacheLookup = nil; cacheWriting?.cancel()
        guard let cache else { return }
        Task {
            do { try await cache.clear(); cacheBytes = 0; cacheMessage = "Saved OCR cleared. The open PDF stays available." }
            catch { cacheMessage = "Could not clear saved OCR: \(error.localizedDescription)" }
        }
    }

    func beginRegionSelection() {
        guard document?.allowsCopying == true else { return }
        selectingRegion = true; displayUpdate?.cancel()
    }
    func cancelRegionSelection() { selectingRegion = false; scheduleDisplayUpdate() }
    func recognizeSelectedArea() {
        guard let view = pdfView, let selection = view.currentSelection,
              let page = selection.pages.first, selection.pages.count == 1 else {
            error = "Select text on one page, or draw an area to recognize."; return
        }
        recognizeRegion(page: page, rect: selection.bounds(for: page).insetBy(dx: -2, dy: -2))
    }
    func recognizeArea(inView rect: CGRect) {
        selectingRegion = false
        defer { scheduleDisplayUpdate() }
        guard let view = pdfView else { return }
        var rect = rect
        #if os(macOS)
        if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
        #endif
        guard rect.width >= 8, rect.height >= 8,
              let page = view.page(for: CGPoint(x: rect.midX, y: rect.midY), nearest: false),
              view.page(for: CGPoint(x: rect.minX, y: rect.minY), nearest: false) === page,
              view.page(for: CGPoint(x: rect.maxX, y: rect.maxY), nearest: false) === page else {
            error = "Draw an area inside one PDF page."; return
        }
        recognizeRegion(page: page, rect: view.convert(rect, to: page))
    }
    private func recognizeRegion(page: PDFPage, rect: CGRect) {
        guard document?.allowsCopying == true, let copy = page.copy() as? PDFPage else { return }
        let standalone = PDFDocument(); standalone.insert(copy, at: 0)
        guard let data = standalone.dataRepresentation() else { return }
        regionJob?.cancel(); regionGeneration = UUID()
        let token = regionGeneration
        showsRegionResult = true; recognizingRegion = true; regionText = ""; regionMessage = ""
        regionJob = Task { [weak self, regionWorker] in
            do {
                let text = try await regionWorker.recognize(data: data, region: rect)
                guard let self, !Task.isCancelled, self.regionGeneration == token else { return }
                self.regionText = text; self.recognizingRegion = false
                self.regionMessage = text.isEmpty ? "No text found. Try a slightly larger area." : "Select text below, or tap a word to copy it."
            } catch {
                guard let self, !Task.isCancelled, self.regionGeneration == token else { return }
                self.recognizingRegion = false; self.regionMessage = "Recognition failed. Try another area."
            }
        }
    }
    func dismissRegionResult() { regionJob?.cancel(); regionGeneration = UUID(); recognizingRegion = false; showsRegionResult = false }
    func copyText(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    func showSearch() { showsSearch = true; search.focusRequest = UUID() }

    func copySelection() {
        #if os(macOS)
        pdfView?.copy(nil)
        #else
        guard document?.allowsCopying == true, let text = pdfView?.currentSelection?.string else { return }
        UIPasteboard.general.string = text
        #endif
    }
    func movePage(_ delta: Int) {
        guard let page = document?.page(at: max(0, min(pageCount - 1, currentPage + delta))) else { return }
        pdfView?.go(to: page)
    }
}
