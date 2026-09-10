import Foundation
import PDFKit

public enum RegionRecognizer {
    /// Input is a rectangle in the PDF page's coordinate system, including crop/rotation.
    public static func recognize(_ page: PDFPage, region: CGRect,
                                 engine: any TextRecognizer = VisionTextRecognizer()) throws -> [RecognizedRun] {
        let (bounds, transform) = try PageRecognizer.geometry(for: page)
        let crop = region.standardized.applying(transform).intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1, let ref = page.pageRef else { throw RecognitionError.invalidPage }
        let scale = min(max(6, 1600 / max(crop.width, crop.height)), sqrt(8_000_000 / (crop.width * crop.height)))
        let width = max(1, Int(ceil(crop.width * scale))), height = max(1, Int(ceil(crop.height * scale)))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RecognitionError.renderingFailed }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: CGFloat(width) / crop.width, y: CGFloat(height) / crop.height)
        bitmap.translateBy(x: -crop.minX, y: -crop.minY)
        bitmap.concatenate(transform); bitmap.drawPDFPage(ref)
        guard let image = bitmap.makeImage() else { throw RecognitionError.renderingFailed }
        try Task.checkCancellation()
        let runs = try engine.recognize(image, pageSize: crop.size)
        try Task.checkCancellation()
        return runs
    }
    public static func text(from runs: [RecognizedRun]) -> String {
        // A focused region is read top-to-bottom, then left-to-right within a line.
        var lines: [[RecognizedRun]] = []
        for run in runs.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let index = lines.firstIndex(where: { line in
                guard let first = line.first else { return false }
                return abs(first.bounds.midY - run.bounds.midY) < min(first.bounds.height, run.bounds.height) * 0.6
            }) { lines[index].append(run) } else { lines.append([run]) }
        }
        return lines.map { $0.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }
}
