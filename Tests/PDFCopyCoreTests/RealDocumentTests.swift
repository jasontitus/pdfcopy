import XCTest
import AppKit
import PDFKit
import PDFCopyCore

final class RealDocumentTests: XCTestCase {
    final class RecordingEngine: TextRecognizer {
        var runs: [RecognizedRun] = []
        func recognize(_ image: CGImage, pageSize: CGSize) throws -> [RecognizedRun] {
            runs = try VisionTextRecognizer().recognize(image, pageSize: pageSize)
            return runs
        }
    }

    func testUserDocumentsWhenProvided() throws {
        guard let folder = ProcessInfo.processInfo.environment["PDFCOPY_TEST_DOCUMENTS"] else {
            throw XCTSkip("Set PDFCOPY_TEST_DOCUMENTS to opt in to local real-document validation")
        }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDFCOPY_TEST_OUTPUT"] ?? ".build/validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty)
        var report: [[String: Any]] = []
        for (fileIndex, file) in files.enumerated() {
            let originalBytes = try Data(contentsOf: file)
            let document = try XCTUnwrap(PDFDocument(data: originalBytes))
            XCTAssertFalse(document.isLocked)
            var pages: [[String: Any]] = []
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index))
                let native = page.string ?? ""
                let engine = RecordingEngine()
                let started = Date()
                let result = try PageRecognizer.process(page, engine: engine)
                try native.write(to: output.appendingPathComponent("file-\(fileIndex + 1)-page-\(index + 1)-native.txt"), atomically: true, encoding: .utf8)
                try engine.runs.map(\.text).joined(separator: " ").write(to: output.appendingPathComponent("file-\(fileIndex + 1)-page-\(index + 1)-ocr.txt"), atomically: true, encoding: .utf8)
                let elapsed = Date().timeIntervalSince(started)
                let recognizedDocument = result.pdfData.flatMap(PDFDocument.init(data:))
                let recognized = recognizedDocument?.page(at: 0) ?? page
                let text = recognized.string ?? ""
                XCTAssertGreaterThanOrEqual(text.count, native.count, "Native content lost in file \(fileIndex + 1), page \(index + 1)")
                XCTAssertFalse(text.isEmpty, "No text on file \(fileIndex + 1), page \(index + 1)")
                let sourceImage = try render(page)
                let resultImage = try render(recognized)
                let before = try XCTUnwrap(sourceImage.dataProvider?.data) as Data
                let after = try XCTUnwrap(resultImage.dataProvider?.data) as Data
                let changed = zip(before, after).filter { abs(Int($0) - Int($1)) > 3 }.count
                let difference = Double(changed) / Double(max(1, before.count))
                XCTAssertLessThan(difference, 0.001, "Page appearance changed in file \(fileIndex + 1), page \(index + 1)")
                for (label, image) in [("source", sourceImage), ("result", resultImage)] {
                    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("file-\(fileIndex + 1)-page-\(index + 1)-\(label).png"))
                }
                let (_, transform) = try PageRecognizer.geometry(for: page)
                var hits = 0, attempted = 0, rangeHits = 0
                var misses: [String] = []
                for run in engine.runs {
                    let center = CGPoint(x: run.bounds.midX, y: run.bounds.midY)
                    // Existing native text is authoritative; evaluate OCR-only locations.
                    func comparable(_ text: String) -> String {
                        text.lowercased().filter { $0.isLetter || $0.isNumber }
                    }
                    let target = comparable(run.text)
                    guard !target.isEmpty else { continue }
                    let nativeAtLocation = page.selection(for: run.bounds.applying(transform.inverted()))?.string ?? ""
                    if comparable(nativeAtLocation).contains(target) { continue }
                    attempted += 1
                    let selected = recognized.selectionForWord(at: center)?.string ?? ""
                    if comparable(selected).contains(target) { hits += 1 }
                    else { misses.append(run.text) }
                    let selectedRange = recognized.selection(for: run.bounds.insetBy(dx: -0.5, dy: -0.5))?.string ?? ""
                    if comparable(selectedRange).contains(target) { rangeHits += 1 }
                }
                try text.write(to: output.appendingPathComponent("file-\(fileIndex + 1)-page-\(index + 1).txt"), atomically: true, encoding: .utf8)
                pages.append(["page": index + 1, "nativeCharacters": native.count,
                    "resultCharacters": text.count, "addedWords": result.addedWordCount,
                    "seconds": elapsed, "changedPixelFraction": difference,
                    "wordSelectionHits": hits, "wordSelectionAttempts": attempted,
                    "regionSelectionHits": rangeHits, "selectionMisses": misses])
                print("File \(fileIndex + 1), page \(index + 1): \(native.count) → \(text.count) characters; \(result.addedWordCount) OCR words; \(hits)/\(attempted) word hit tests; \(String(format: "%.2f", elapsed)) s; pixel change \(difference)")
            }
            XCTAssertEqual(try Data(contentsOf: file), originalBytes, "Original file must remain unchanged")
            report.append(["file": file.lastPathComponent, "pages": pages])
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
    }

    private func render(_ page: PDFPage) throws -> CGImage {
        let (bounds, transform) = try PageRecognizer.geometry(for: page)
        let scale = 1200 / max(bounds.width, bounds.height)
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        bitmap.concatenate(transform); bitmap.drawPDFPage(try XCTUnwrap(page.pageRef))
        return try XCTUnwrap(bitmap.makeImage())
    }
}
