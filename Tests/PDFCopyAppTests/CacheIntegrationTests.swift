import XCTest
import PDFKit
import CoreText
import PDFCopyCore
@testable import PDFCopy

final class CacheIntegrationTests: XCTestCase {
    private func source() throws -> PDFDocument {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 300, height: 190)
        let pdf = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        pdf.beginPDFPage(nil); pdf.setFillColor(CGColor(gray: 1, alpha: 1)); pdf.fill(box)
        pdf.setFillColor(CGColor(gray: 0, alpha: 1)); pdf.textPosition = CGPoint(x: 30, y: 100)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Saved words reopen quickly", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font])), pdf)
        pdf.endPDFPage(); pdf.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
    @MainActor private func finish(_ model: DocumentModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while (model.running || model.openingCache || !model.waitingPages.isEmpty || model.readyPages.isEmpty), Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(model.running); XCTAssertFalse(model.openingCache)
        XCTAssertEqual(model.readyPages.count, 1)
    }
    @MainActor func testCacheReopenAndClearDuringCurrentDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PDFCopyTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = OCRCache(directory: root.appendingPathComponent("cache"))
        let data = try XCTUnwrap(source().dataRepresentation()), url = root.appendingPathComponent("source.pdf")
        try data.write(to: url)
        let first = DocumentModel(cache: cache, defaults: defaults); let view = PDFView()
        first.attach(view); first.open(url); view.document = first.document
        try await finish(first)
        let storeDeadline = Date().addingTimeInterval(3)
        while await cache.size() == 0, Date() < storeDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let stored = await cache.lookup(source: data); XCTAssertNotNil(stored.data)
        let second = DocumentModel(cache: cache, defaults: defaults); let other = PDFView()
        second.attach(other); second.open(url); other.document = second.document
        let deadline = Date().addingTimeInterval(3)
        while second.readyPages.isEmpty, Date() < deadline {
            XCTAssertFalse(second.running, "Cache hit must not rerun OCR")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(second.readyPages.count, 1)
        XCTAssertTrue(second.document?.string?.contains("Saved words") == true)
        second.setRemembersOCR(false)
        XCTAssertFalse(second.remembersOCR)
        let clearDeadline = Date().addingTimeInterval(3)
        while await cache.size() > 0, Date() < clearDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        second.retryPage(); try await finish(second)
        let after = await cache.lookup(source: data); XCTAssertNil(after.data)
    }
    @MainActor func testSelectedAreaPreviewAndCancellation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(UUID()).pdf")
        try XCTUnwrap(source().dataRepresentation()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = DocumentModel(cache: nil)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        model.attach(view); model.open(url); view.document = model.document
        try await finish(model)
        let original = model.document
        let selection = try XCTUnwrap(model.document?.findString("Saved words", withOptions: []).first)
        view.setCurrentSelection(selection, animate: false); model.selectionChanged()
        model.recognizeSelectedArea()
        let deadline = Date().addingTimeInterval(10)
        while model.recognizingRegion, Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(model.regionText.contains("Saved words"), model.regionText)
        XCTAssertTrue(model.document === original, "Region preview must not edit the displayed PDF")
        model.recognizeSelectedArea(); model.open(url)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(model.showsRegionResult)
        XCTAssertTrue(model.regionText.isEmpty, "A cancelled region result must not appear over a new PDF")
    }

    @MainActor func testPasswordProtectedPDFIsNeverCached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try XCTUnwrap(source().dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "test-password", PDFDocumentWriteOption.ownerPasswordOption: "test-owner"]))
        let url = root.appendingPathComponent("protected.pdf"); try data.write(to: url)
        let cache = OCRCache(directory: root.appendingPathComponent("cache"))
        let suite = "PDFCopyProtectedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "rememberOCR")
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DocumentModel(cache: cache, defaults: defaults); let view = PDFView(); model.attach(view)
        model.open(url); XCTAssertTrue(model.needsPassword)
        model.password = "test-password"; model.unlock(); view.document = model.document
        try await finish(model)
        let result = await cache.lookup(source: data); XCTAssertNil(result.data)
    }
}
