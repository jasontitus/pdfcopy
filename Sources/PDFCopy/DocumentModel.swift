import AppKit
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
    weak var pdfView: PDFView?
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

    var pageCount: Int { document?.pageCount ?? 0 }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let pdf = PDFDocument(data: data), pdf.isLocked || pdf.pageCount > 0 else {
                error = "This file is not a readable PDF."; return
            }
            job?.cancel()
            displayUpdate?.cancel()
            generation = UUID()
            liveScrolling = false; lastViewportActivity = -Double.infinity
            worker = nil
            pending = []; replacements = [:]; forced = []; completed = []; failedPages = []; activeRequest = nil
            processed = 0; currentPage = 0; hasSelection = false; running = false
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
        runQueue()
    }

    func retryPage() {
        guard worker != nil, pageCount > 0 else { return }
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
                self.status = "Recognizing page \(index + 1) of \(self.pageCount) · on this Mac"
                do {
                    let result = try await worker.process(index: index, replace: replace)
                    guard !Task.isCancelled, self.generation == token else { return }
                    if let data = result.pdfData, let replacement = PDFDocument(data: data) {
                        self.replacements[index] = replacement
                        if self.replacements.count >= self.updateBatchSize { self.scheduleDisplayUpdate() }
                    }
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
                ? (self.replacements.isEmpty ? "Ready · double-click a word or drag to select text"
                    : "Text recognized · finishing when the page is idle")
                : "Recognition failed on \(self.failedPages.count) page(s) · use Recognize Again to retry"
            self.scheduleDisplayUpdate()
        }
    }

    func selectionChanged() {
        hasSelection = !(pdfView?.currentSelection?.string?.isEmpty ?? true)
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
        guard !liveScrolling, !hasSelection, !replacements.isEmpty,
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
        guard let document, let view = pdfView,
              !liveScrolling, ProcessInfo.processInfo.systemUptime - lastViewportActivity >= 0.5,
              view.currentSelection?.string?.isEmpty ?? true, !replacements.isEmpty else { return }
        let oldPage = view.currentPage.map { document.index(for: $0) }.flatMap { $0 == NSNotFound ? nil : $0 } ?? currentPage
        let point = view.currentDestination?.point ?? .zero
        let scale = view.scaleFactor
        let scrollOrigin = view.documentView?.enclosingScrollView?.contentView.bounds.origin
        // Do not mutate PDFView's live document. Its accessibility tree retains page
        // references; moving pages between documents can leave stale CoreGraphics roots.
        let staging = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = replacements[index]?.page(at: 0) ?? document.page(at: index),
                  let copy = page.copy() as? PDFPage else { return }
            staging.insert(copy, at: index)
        }
        guard let data = staging.dataRepresentation(), let refreshed = PDFDocument(data: data) else {
            error = "Could not update the PDF with recognized text."; return
        }
        applyingPages = true
        defer { applyingPages = false }
        // Present document, scale, and scroll restoration in a single screen update.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
        }
        CATransaction.commit()
        replacements.removeAll()
        if !running, failedPages.isEmpty {
            status = pending.isEmpty ? "Ready · double-click a word or drag to select text"
                : "Recognition paused · existing text is still selectable"
        }
    }

    func copySelection() { pdfView?.copy(nil) }
    func movePage(_ delta: Int) {
        guard let page = document?.page(at: max(0, min(pageCount - 1, currentPage + delta))) else { return }
        pdfView?.go(to: page)
    }
}
