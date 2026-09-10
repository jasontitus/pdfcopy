import XCTest
import AppKit
import PDFKit
@testable import PDFCopyCore

final class PageRecognizerTests: XCTestCase {
    struct FixedRecognizer: TextRecognizer {
        let runs: [RecognizedRun]
        func recognize(_ image: CGImage, pageSize: CGSize) throws -> [RecognizedRun] { runs }
    }

    func makePDF(scanned: Bool, rotation: Int = 0, mixed: Bool = false) throws -> PDFPage {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        if scanned || mixed {
            let imageContext = CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            imageContext.setFillColor(CGColor(gray: 1, alpha: 1))
            imageContext.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
            imageContext.scaleBy(x: 2, y: 2)
            draw("Scanned words, ready to copy.", at: CGPoint(x: 60, y: 550), in: imageContext)
            context.draw(imageContext.makeImage()!, in: bounds)
        }
        if !scanned { draw("Native text stays selectable.", at: CGPoint(x: 60, y: 700), in: context) }
        context.endPDFPage(); context.closePDF()
        let page = try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
        page.rotation = rotation
        return page
    }

    func draw(_ text: String, at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = point
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.restoreGState()
    }

    func testInvisibleLayerIsSelectableAtDetectedLocation() throws {
        let source = try makePDF(scanned: true)
        let box = CGRect(x: 60, y: 540, width: 100, height: 26)
        let result = try PageRecognizer.process(source, engine: FixedRecognizer(runs: [.init(text: "Scanned", bounds: box)]))
        let page = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData))?.page(at: 0))
        XCTAssertEqual(page.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Scanned")
        XCTAssertEqual(page.selectionForWord(at: CGPoint(x: box.midX, y: box.midY))?.string, "Scanned")
        XCTAssertTrue(page.selection(for: box)?.string?.contains("Scanned") == true)
        XCTAssertEqual(source.numberOfCharacters, 0, "Original page must remain unchanged")
    }

    func testVisionRecognizesScanAndProducesCopyableWords() throws {
        let source = try makePDF(scanned: true)
        let result = try PageRecognizer.process(source)
        let page = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData))?.page(at: 0))
        XCTAssertTrue(page.string?.contains("Scanned words, ready to copy.") == true, page.string ?? "No text")
        XCTAssertGreaterThan(result.addedWordCount, 3)
    }

    func testMixedPagePreservesNativeTextWithoutDuplicateOCR() throws {
        let source = try makePDF(scanned: false, mixed: true)
        let result = try PageRecognizer.process(source)
        let page = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData))?.page(at: 0))
        let text = try XCTUnwrap(page.string)
        XCTAssertTrue(text.contains("Scanned words, ready to copy."), text)
        XCTAssertEqual(text.components(separatedBy: "Native").count - 1, 1, text)
        XCTAssertTrue(text.contains("Native text stays selectable."), text)
    }

    func testNativeOnlyPageNeedsNoReplacement() throws {
        let result = try PageRecognizer.process(makePDF(scanned: false))
        XCTAssertNil(result.pdfData)
        XCTAssertEqual(result.addedWordCount, 0)
    }

    func testRotationAndCropUseConsistentGeometry() throws {
        for angle in [0, 90, 180, 270] {
            let page = try makePDF(scanned: true, rotation: angle)
            page.setBounds(CGRect(x: 30, y: 40, width: 550, height: 720), for: .cropBox)
            // Serialize to commit PDFKit crop/rotation changes to the CGPDFPage.
            let doc = PDFDocument(); doc.insert(page, at: 0)
            let reread = try XCTUnwrap(PDFDocument(data: XCTUnwrap(doc.dataRepresentation()))?.page(at: 0))
            let (bounds, _) = try PageRecognizer.geometry(for: reread)
            XCTAssertEqual(bounds.width, angle % 180 == 0 ? 550 : 720)
            let box = CGRect(x: 80, y: 200, width: 90, height: 24)
            let result = try PageRecognizer.process(reread, engine: FixedRecognizer(runs: [.init(text: "Rotated", bounds: box)]))
            let output = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData))?.page(at: 0))
            XCTAssertEqual(output.selectionForWord(at: CGPoint(x: box.midX, y: box.midY))?.string, "Rotated")
            XCTAssertEqual(output.bounds(for: .mediaBox).size, bounds.size)
        }
    }

    func testForcedRecognitionReplacesBrokenNativeLayer() throws {
        let source = try makePDF(scanned: false)
        let result = try PageRecognizer.process(source, replaceExistingText: true,
            engine: FixedRecognizer(runs: [.init(text: "Corrected", bounds: CGRect(x: 60, y: 700, width: 150, height: 24))]))
        let page = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData))?.page(at: 0))
        XCTAssertEqual(page.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Corrected")
        XCTAssertTrue(source.string?.contains("Native") == true)
    }

    func testInvisibleTextDoesNotChangeRenderedAppearance() throws {
        let source = try makePDF(scanned: true)
        let result = try PageRecognizer.process(source, engine: FixedRecognizer(runs: [
            .init(text: "Invisible overlay", bounds: CGRect(x: 40, y: 400, width: 200, height: 40))]))
        let output = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData))?.page(at: 0))
        func pixels(_ page: PDFPage) throws -> Data {
            let (bounds, transform) = try PageRecognizer.geometry(for: page)
            let bitmap = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(bounds)
            bitmap.concatenate(transform); bitmap.drawPDFPage(page.pageRef!)
            return Data(bytes: bitmap.data!, count: 612 * 792 * 4)
        }
        XCTAssertEqual(try pixels(source), try pixels(output), "Adding OCR must not paint over the document")
    }

    func testTightlySpacedOCRWordsKeepWordSeparators() throws {
        let source = try makePDF(scanned: true)
        let result = try PageRecognizer.process(source, engine: FixedRecognizer(runs: [
            .init(text: "is", bounds: CGRect(x: 40, y: 400, width: 20, height: 20)),
            .init(text: "an", bounds: CGRect(x: 60.5, y: 400, width: 20, height: 20))]))
        let document = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.pdfData)))
        XCTAssertTrue(document.string?.contains("is an") == true, document.string ?? "No text")
    }
}
