import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Vision

public struct RecognizedRun {
    public let text: String
    /// Coordinates in the rendered page, in PDF points with a bottom-left origin.
    public let bounds: CGRect
    public let confidence: Float
    public init(text: String, bounds: CGRect, confidence: Float = 1) {
        self.text = text; self.bounds = bounds; self.confidence = confidence
    }
}

public protocol TextRecognizer {
    func recognize(_ image: CGImage, pageSize: CGSize) throws -> [RecognizedRun]
}

public struct VisionTextRecognizer: TextRecognizer {
    public init() {}
    public func recognize(_ image: CGImage, pageSize: CGSize) throws -> [RecognizedRun] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.003
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).flatMap { observation -> [RecognizedRun] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            let string = candidate.string
            // Keep punctuation with its word so copying preserves what was recognized.
            var runs: [RecognizedRun] = []
            let regex = try! NSRegularExpression(pattern: "\\S+")
            for match in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
                guard let range = Range(match.range, in: string),
                      let box = try? candidate.boundingBox(for: range) else { continue }
                let normalized = box.boundingBox
                runs.append(RecognizedRun(text: String(string[range]), bounds: CGRect(
                    x: normalized.minX * pageSize.width, y: normalized.minY * pageSize.height,
                    width: normalized.width * pageSize.width, height: normalized.height * pageSize.height),
                    confidence: candidate.confidence))
            }
            return runs
        }
    }
}

public enum RecognitionError: LocalizedError {
    case invalidPage, renderingFailed, writingFailed
    public var errorDescription: String? {
        switch self {
        case .invalidPage: return "This PDF page could not be read."
        case .renderingFailed: return "This page could not be rendered for text recognition."
        case .writingFailed: return "The selectable text layer could not be created."
        }
    }
}

public struct PageRecognitionResult {
    public let pdfData: Data?
    public let addedWordCount: Int
}

public enum PageRecognizer {
    /// Rasterization and the PDF text layer use the same transform, including crop and rotation.
    public static func geometry(for page: PDFPage) throws -> (CGRect, CGAffineTransform) {
        guard let ref = page.pageRef else { throw RecognitionError.invalidPage }
        let crop = ref.getBoxRect(.cropBox)
        let quarterTurn = abs(ref.rotationAngle % 180) == 90
        let bounds = CGRect(origin: .zero, size: quarterTurn
            ? CGSize(width: crop.height, height: crop.width) : crop.size)
        guard bounds.width > 0, bounds.height > 0 else { throw RecognitionError.invalidPage }
        return (bounds, ref.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
    }

    public static func process(_ page: PDFPage, replaceExistingText: Bool = false,
                               engine: any TextRecognizer = VisionTextRecognizer()) throws -> PageRecognitionResult {
        guard let ref = page.pageRef else { throw RecognitionError.invalidPage }
        let (bounds, transform) = try geometry(for: page)
        // Keep card-sized scans large enough for small lettering. Ordinary pages retain
        // the 216 DPI baseline; all renders remain capped at 16 MP.
        let scale = min(max(3, 1600 / max(bounds.width, bounds.height)),
                        sqrt(16_000_000 / (bounds.width * bounds.height)))
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RecognitionError.renderingFailed }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        bitmap.concatenate(transform)
        bitmap.drawPDFPage(ref)
        guard let image = bitmap.makeImage() else { throw RecognitionError.renderingFailed }
        let recognized = try engine.recognize(image, pageSize: bounds.size)
        try Task.checkCancellation()

        let rebuildText = replaceExistingText || shouldRebuildScanText(page, recognized: recognized, transform: transform)
        let nativeBoxes: [CGRect] = rebuildText ? [] : (0..<page.numberOfCharacters).compactMap { index in
            let box = page.characterBounds(at: index).applying(transform)
            return box.isEmpty || box.isInfinite || box.isNull ? nil : box
        }
        // Trust embedded text only when both its position and characters agree.
        // Broken font mappings can report large bounds for very little usable text.
        let additions = recognized.filter { run in
            guard !run.bounds.isEmpty else { return false }
            let covered = nativeBoxes.reduce(CGFloat.zero) { partial, box in
                let overlap = run.bounds.intersection(box)
                return partial + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            guard covered / (run.bounds.width * run.bounds.height) >= 0.25 else { return true }
            let nativeText = page.selection(for: run.bounds.applying(transform.inverted()))?.string ?? ""
            let expected = normalized(run.text)
            return expected.isEmpty || !normalized(nativeText).contains(expected)
        }
        guard !additions.isEmpty else { return PageRecognitionResult(pdfData: nil, addedWordCount: 0) }

        let output = NSMutableData()
        var mediaBox = bounds
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw RecognitionError.writingFailed }
        context.beginPDFPage(nil)
        if rebuildText {
            context.draw(image, in: bounds)
        } else {
            context.saveGState()
            context.concatenate(transform)
            context.drawPDFPage(ref)
            context.restoreGState()
        }
        for run in additions { drawInvisible(run, in: context) }
        context.endPDFPage()
        context.closePDF()
        return PageRecognitionResult(pdfData: output as Data, addedWordCount: additions.count)
    }

    private static func shouldRebuildScanText(_ page: PDFPage, recognized: [RecognizedRun],
                                              transform: CGAffineTransform) -> Bool {
        guard let ref = page.pageRef, ScanTextLayer.isImageWithOnlyInvisibleText(ref) else { return false }
        let native = normalized(page.string ?? "")
        let fresh = normalized(recognized.map(\.text).joined(separator: " "))
        // Do not discard a populated OCR layer when the new engine recognizes very
        // little (for example, an unsupported script). A manual retry remains available.
        guard !native.isEmpty, Double(fresh.count) >= Double(native.count) * 0.8 else { return false }
        return recognized.contains { run in
            let expected = normalized(run.text)
            guard run.confidence >= 0.85, expected.count >= 3 else { return false }
            let embedded = normalized(page.selection(for: run.bounds.applying(transform.inverted()))?.string ?? "")
            return !embedded.isEmpty && !embedded.contains(expected)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func drawInvisible(_ run: RecognizedRun, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        // Explicit separators prevent PDFKit joining close OCR boxes into "isan".
        let attributed = NSAttributedString(string: run.text + " ",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            - CTLineGetTrailingWhitespaceWidth(line))
        guard width > 0, ascent + descent > 0 else { return }
        context.saveGState()
        context.translateBy(x: run.bounds.minX, y: run.bounds.minY)
        context.scaleBy(x: run.bounds.width / width, y: run.bounds.height / (ascent + descent))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: descent)
        context.setTextDrawingMode(.invisible)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
