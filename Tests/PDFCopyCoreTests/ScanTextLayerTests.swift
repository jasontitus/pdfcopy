import XCTest
import PDFKit
import CoreText
@testable import PDFCopyCore

final class ScanTextLayerTests: XCTestCase {
    private let boxes = [CGRect(x: 80, y: 110, width: 80, height: 16),
                         CGRect(x: 170, y: 110, width: 65, height: 16)]
    private struct Fixed: TextRecognizer {
        let runs: [RecognizedRun]
        func recognize(_ image: CGImage, pageSize: CGSize) throws -> [RecognizedRun] { runs }
    }
    private func draw(_ text: String, at point: CGPoint, in context: CGContext) {
        context.textMatrix = .identity; context.textPosition = point
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
    }
    private func fixture(hidden: [String], visibleText: Bool = false) throws -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 190)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 760, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.scaleBy(x: 4, y: 4)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(bounds)
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        draw("MORGAN", at: boxes[0].origin, in: bitmap)
        draw("RILEY", at: boxes[1].origin, in: bitmap)
        let data = NSMutableData(); var media = bounds
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.draw(try XCTUnwrap(bitmap.makeImage()), in: bounds)
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for (index, text) in hidden.enumerated() { draw(text, at: boxes[index].origin, in: context) }
        context.restoreGState()
        if visibleText { draw("Visible reference", at: CGPoint(x: 30, y: 40), in: context) }
        context.endPDFPage(); context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
    private var fresh: [RecognizedRun] {
        [.init(text: "MORGAN", bounds: boxes[0]), .init(text: "RILEY", bounds: boxes[1])]
    }

    func testStaleHiddenOCRIsReplacedInsteadOfDuplicated() throws {
        let original = try fixture(hidden: ["M0RG4N", "R1LEY"])
        let source = try XCTUnwrap(original.page(at: 0))
        XCTAssertTrue(ScanTextLayer.isImageWithOnlyInvisibleText(try XCTUnwrap(source.pageRef)))
        let result = try PageRecognizer.process(source, engine: Fixed(runs: fresh))
        let repaired = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData)))
        let page = try XCTUnwrap(repaired.page(at: 0))
        XCTAssertFalse(page.string?.contains("M0RG4N") == true)
        XCTAssertFalse(page.string?.contains("R1LEY") == true)
        for run in fresh {
            for fraction in [0.25, 0.5, 0.75] {
                let point = CGPoint(x: run.bounds.minX + run.bounds.width * fraction, y: run.bounds.midY)
                XCTAssertEqual(page.selectionForWord(at: point)?.string, run.text)
            }
        }
        XCTAssertTrue(source.string?.contains("M0RG4N") == true, "Never modify the source PDF")
    }

    func testVisionRepairsTheHiddenTextOnACardScan() throws {
        let original = try fixture(hidden: ["M0RG4N", "R1LEY"])
        let result = try PageRecognizer.process(XCTUnwrap(original.page(at: 0)))
        let repaired = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData)))
        let text = repaired.string ?? ""
        XCTAssertTrue(text.contains("MORGAN"), text)
        XCTAssertTrue(text.contains("RILEY"), text)
        XCTAssertFalse(text.contains("M0RG4N"), text)
        XCTAssertFalse(text.contains("R1LEY"), text)
    }

    func testCorrectHiddenOCRNeedsNoRebuild() throws {
        let original = try fixture(hidden: ["MORGAN", "RILEY"])
        let result = try PageRecognizer.process(XCTUnwrap(original.page(at: 0)), engine: Fixed(runs: fresh))
        XCTAssertNil(result.pdfData)
    }

    func testVisibleTextPreventsAutomaticFlattening() throws {
        let original = try fixture(hidden: ["M0RG4N", "R1LEY"], visibleText: true)
        let source = try XCTUnwrap(original.page(at: 0))
        XCTAssertFalse(ScanTextLayer.isImageWithOnlyInvisibleText(try XCTUnwrap(source.pageRef)))
        let result = try PageRecognizer.process(source, engine: Fixed(runs: fresh))
        let repaired = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData)))
        XCTAssertTrue(repaired.string?.contains("Visible reference") == true)
        XCTAssertTrue(repaired.string?.contains("M0RG4N") == true)
    }

    func testLowCoverageOrConfidenceDoesNotDiscardExistingOCR() throws {
        let original = try fixture(hidden: ["M0RG4N", "R1LEY"])
        for runs in [[fresh[0]], fresh.map({ RecognizedRun(text: $0.text, bounds: $0.bounds, confidence: 0.3) })] {
            let result = try PageRecognizer.process(XCTUnwrap(original.page(at: 0)), engine: Fixed(runs: runs))
            let repaired = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData)))
            XCTAssertTrue(repaired.string?.contains("M0RG4N") == true)
        }
    }

    func testCardScanKeepsEnoughRasterResolution() throws {
        final class SizeRecorder: TextRecognizer {
            var width = 0
            func recognize(_ image: CGImage, pageSize: CGSize) throws -> [RecognizedRun] { width = image.width; return [] }
        }
        let original = try fixture(hidden: [])
        let engine = SizeRecorder()
        _ = try PageRecognizer.process(XCTUnwrap(original.page(at: 0)), engine: engine)
        XCTAssertGreaterThanOrEqual(engine.width, 1600)
    }
}
