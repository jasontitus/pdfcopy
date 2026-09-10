import XCTest
import PDFKit
import UIKit
@testable import PDFCopy

final class MobileDocumentTests: XCTestCase {
    @MainActor func testScanOCRSearchCopyAndDeferredRefresh() async throws {
        let size = CGSize(width: 612, height: 792)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            ("Mobile scanned words." as NSString).draw(at: CGPoint(x: 50, y: 90), withAttributes: [
                .font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.black])
        }
        let source = PDFDocument()
        for _ in 0..<3 { source.insert(try XCTUnwrap(PDFPage(image: image)), at: source.pageCount) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID()).pdf")
        try XCTUnwrap(source.dataRepresentation()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = DocumentModel(cache: nil)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 650))
        view.displayMode = .singlePageContinuous
        model.pdfView = view
        model.open(url)
        view.document = model.document
        view.scaleFactor = 0.7; view.layoutDocumentView()
        let coordinator = MobilePDFView.Coordinator(model: model); coordinator.observe(view)
        model.search.attach(document: model.document, view: view)
        model.search.query = "scanned"
        let original = model.document
        model.scrollActivity(began: true)
        let scroll = try XCTUnwrap(view.contentScrollView)
        scroll.contentOffset = CGPoint(x: 0, y: 400)
        let offset = scroll.contentOffset
        let scale = view.scaleFactor
        let deadline = Date().addingTimeInterval(30)
        while model.running, Date() < deadline { try await Task.sleep(nanoseconds: 40_000_000) }
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.failedPages.isEmpty)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(model.document === original)
        model.scrollActivity(ended: true)
        let applyDeadline = Date().addingTimeInterval(5)
        while (model.document === original || model.search.searching), Date() < applyDeadline {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertFalse(model.document === original)
        XCTAssertEqual(model.search.matches.count, 3)
        XCTAssertEqual(view.scaleFactor, scale, accuracy: 0.001)
        XCTAssertEqual(view.contentScrollView?.contentOffset.y ?? -1, offset.y, accuracy: 1)
        let selection = try XCTUnwrap(model.search.matches.first)
        view.setCurrentSelection(selection, animate: false)
        model.selectionChanged()
        model.copySelection()
        XCTAssertTrue(model.hasSelection)
        XCTAssertEqual(UIPasteboard.general.string?.lowercased(), "scanned")
        coordinator.stop()
    }
}
