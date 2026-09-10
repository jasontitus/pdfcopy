import AppKit
import PDFKit
import XCTest
import PDFCopyCore
@testable import PDFCopy

final class DocumentModelTests: XCTestCase {
    @MainActor
    func testBackgroundOCRUpdatesLiveViewAndRetainsSelection() async throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 612, height: 792).fill()
        ("Select these scanned words." as NSString).draw(at: NSPoint(x: 60, y: 650),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let source = PDFDocument()
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfcopy-\(UUID()).pdf")
        try XCTUnwrap(source.dataRepresentation()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try PageRecognizer.process(XCTUnwrap(PDFDocument(url: url)?.page(at: 0)))
        XCTAssertGreaterThan(baseline.addedWordCount, 0, "Fixture must contain recognizable image text")
        let recognized = try XCTUnwrap(PDFDocument(data: XCTUnwrap(baseline.pdfData)))
        let copy = try XCTUnwrap(recognized.page(at: 0)?.copy() as? PDFPage)
        XCTAssertNotNil(copy.string, "Page copy must retain OCR")
        let staging = PDFDocument(); staging.insert(copy, at: 0)
        XCTAssertNotNil(PDFDocument(data: try XCTUnwrap(staging.dataRepresentation()))?.string, "Serialization must retain OCR")
        let model = DocumentModel()
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        model.pdfView = view
        model.open(url)
        view.document = model.document
        let deadline = Date().addingTimeInterval(20)
        while model.running, Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.failedPages.isEmpty)
        XCTAssertEqual(model.processed, 2)
        XCTAssertEqual(view.document?.pageCount, 2)
        let page = try XCTUnwrap(view.document?.page(at: 0))
        XCTAssertTrue(page.string?.contains("Select these scanned words.") == true, page.string ?? "No recognized text in view")
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        view.setCurrentSelection(selection, animate: false)
        model.selectionChanged()
        XCTAssertTrue(model.hasSelection)
        XCTAssertTrue(view.currentSelection?.string?.contains("scanned") == true)
        // Exercise PDFKit's accessibility hierarchy after rebuilding the document.
        func visit(_ element: Any, depth: Int = 0) {
            guard depth < 12, let accessible = element as? NSAccessibilityProtocol else { return }
            for child in accessible.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        visit(view)
        let selectedDocument = model.document
        let selectedText = view.currentSelection?.string
        model.retryPage()
        let retryDeadline = Date().addingTimeInterval(20)
        while model.running, Date() < retryDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.document === selectedDocument, "Do not replace the document during selection")
        XCTAssertEqual(view.currentSelection?.string, selectedText)
        view.clearSelection()
        model.selectionChanged()
        XCTAssertFalse(model.document === selectedDocument, "Apply the pending OCR after selection ends")
        XCTAssertTrue(view.document?.page(at: 0)?.string?.contains("scanned") == true)
        visit(view)
    }
}
