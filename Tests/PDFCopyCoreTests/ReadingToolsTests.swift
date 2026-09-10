import XCTest
import PDFKit
import CoreText
@testable import PDFCopyCore

final class ReadingToolsTests: XCTestCase {
    private func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, in context: CGContext) {
        context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: y)
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
    }
    private func fixture(scanned: Bool, skew: Bool = false) throws -> PDFDocument {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let output = NSMutableData()
        let pdf = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: output)), mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1836, height: 2376, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.scaleBy(x: 3, y: 3)
        let context = scanned ? bitmap : pdf
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        draw("MORGAN RILEY", x: 50, y: 700, size: 18, in: context)
        draw("Left column", x: 50, y: 600, size: 18, in: context)
        draw("Right column", x: 370, y: 600, size: 18, in: context)
        draw("Apples", x: 50, y: 500, size: 18, in: context)
        draw("12", x: 370, y: 500, size: 18, in: context)
        draw("Oranges", x: 50, y: 470, size: 18, in: context)
        draw("24", x: 370, y: 470, size: 18, in: context)
        context.saveGState()
        if skew { context.translateBy(x: 50, y: 300); context.rotate(by: 3 * .pi / 180) }
        context.setFillColor(CGColor(gray: 0.35, alpha: 1))
        draw("Small print stays readable", x: skew ? 0 : 50, y: skew ? 0 : 300, size: 10, in: context)
        context.restoreGState()
        if scanned { pdf.draw(try XCTUnwrap(bitmap.makeImage()), in: box) }
        pdf.endPDFPage(); pdf.closePDF()
        return try XCTUnwrap(PDFDocument(data: output as Data))
    }
    func testExactNameWordAndColumnSelection() throws {
        let doc = try fixture(scanned: false); let page = try XCTUnwrap(doc.page(at: 0))
        for text in ["MORGAN", "RILEY", "Left", "Right", "Apples", "Oranges"] {
            let selection = try XCTUnwrap(doc.findString(text, withOptions: []).first)
            let box = selection.bounds(for: page)
            XCTAssertEqual(PreciseTextSelection.word(on: page, at: CGPoint(x: box.midX, y: box.midY))?.string, text)
        }
        XCTAssertNil(PreciseTextSelection.word(on: page, at: CGPoint(x: 300, y: 780), tolerance: 5))
    }
    func testSkewSmallPrintColumnsAndTableScan() throws {
        let original = try fixture(scanned: true, skew: true)
        let result = try PageRecognizer.process(XCTUnwrap(original.page(at: 0)))
        let doc = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData)))
        let text = doc.string ?? ""
        for expected in ["MORGAN", "RILEY", "Left", "Right", "Apples", "Oranges", "12", "24", "Small print stays readable"] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected): \(text)")
        }
    }
    func testFocusedRecognitionExcludesAdjacentColumnAndKeepsSource() throws {
        let original = try fixture(scanned: true)
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            bitmap.drawPDFPage(try XCTUnwrap(original.page(at: 0)?.pageRef))
            return Data(bytes: try XCTUnwrap(bitmap.data), count: 612 * 792 * 4)
        }
        let before = try pixels()
        let runs = try RegionRecognizer.recognize(XCTUnwrap(original.page(at: 0)),
            region: CGRect(x: 40, y: 590, width: 180, height: 40))
        let text = RegionRecognizer.text(from: runs)
        XCTAssertTrue(text.contains("Left column"), text)
        XCTAssertFalse(text.contains("Right"), text)
        XCTAssertEqual(try pixels(), before)
    }
    func testRegionCoordinatesRespectCropAndRotation() throws {
        final class Recorder: TextRecognizer {
            var size = CGSize.zero
            func recognize(_ image: CGImage, pageSize: CGSize) throws -> [RecognizedRun] { size = pageSize; return [] }
        }
        for angle in [0, 90, 180, 270] {
            let doc = try fixture(scanned: false)
            let page = try XCTUnwrap(doc.page(at: 0)); page.rotation = angle
            page.setBounds(CGRect(x: 20, y: 30, width: 570, height: 730), for: .cropBox)
            let reread = try XCTUnwrap(PDFDocument(data: XCTUnwrap(doc.dataRepresentation())))
            let recorder = Recorder()
            _ = try RegionRecognizer.recognize(XCTUnwrap(reread.page(at: 0)), region: CGRect(x: 40, y: 590, width: 180, height: 40), engine: recorder)
            XCTAssertEqual(recorder.size.width, angle % 180 == 0 ? 180 : 40, accuracy: 0.01)
            XCTAssertEqual(recorder.size.height, angle % 180 == 0 ? 40 : 180, accuracy: 0.01)
        }
    }
}
