import XCTest
import PDFKit
import CoreText
@testable import PDFCopy

final class PDFSearchTests: XCTestCase {
    private func document(_ lines: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for text in lines {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 500)
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
    @MainActor private func wait(_ search: PDFSearchModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while search.searching, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(search.searching)
    }

    @MainActor func testCaseInsensitiveSearchNavigationAndCopySelection() async throws {
        let document = try document(["Alpha beta ALPHA", "Another alpha here"])
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600)); view.document = document
        let selected = try XCTUnwrap(document.page(at: 0)?.selection(for: NSRange(location: 6, length: 4)))
        view.setCurrentSelection(selected, animate: false)
        let search = PDFSearchModel(); search.attach(document: document, view: view)
        search.query = "alpha"
        try await wait(search)
        XCTAssertEqual(search.matches.count, 3)
        XCTAssertEqual(search.currentIndex, 0)
        XCTAssertEqual(view.currentSelection?.string, "beta", "Find must not replace the user's copy selection")
        XCTAssertEqual(view.highlightedSelections?.count, 3)
        search.move(-1)
        XCTAssertEqual(search.currentIndex, 2)
        XCTAssertTrue(search.matches[2].pages.first === document.page(at: 1))
        search.move(1)
        XCTAssertEqual(search.currentIndex, 0)
        search.query = "unmatched"
        try await wait(search)
        XCTAssertEqual(search.countLabel, "No matches")
        search.query = " "
        XCTAssertEqual(search.matches.count, 0)
        XCTAssertTrue(view.highlightedSelections?.isEmpty ?? true)
    }

    @MainActor func testQueryCancellationAndDocumentRefresh() async throws {
        let original = try document(["First word"])
        let refreshed = try document(["First word", "Scanned word"])
        let view = PDFView(); view.document = original
        let search = PDFSearchModel(); search.attach(document: original, view: view)
        search.query = "First"; search.query = "word"
        try await wait(search)
        XCTAssertEqual(search.matches.count, 1)
        view.document = refreshed
        search.attach(document: refreshed, view: view)
        try await wait(search)
        XCTAssertEqual(search.matches.count, 2, "New OCR text must enter current search results")
        XCTAssertTrue(search.matches.allSatisfy { $0.pages.first?.document === refreshed })
        search.query = "Scanned"
        search.reset()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(search.matches.isEmpty)
        XCTAssertEqual(search.query, "")
    }
}
