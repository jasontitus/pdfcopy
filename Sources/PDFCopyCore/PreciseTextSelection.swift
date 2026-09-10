import Foundation
import PDFKit

public enum PreciseTextSelection {
    /// Use explicit character ranges rather than PDFKit's linguistic word expansion.
    /// Distance is in page coordinates so the caller can keep a constant screen hit target.
    public static func word(on page: PDFPage, at point: CGPoint, tolerance: CGFloat = 0) -> PDFSelection? {
        guard let string = page.string else { return nil }
        let regex = try! NSRegularExpression(pattern: "\\S+")
        var best: (distance: CGFloat, area: CGFloat, selection: PDFSelection)?
        for match in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let selection = page.selection(for: match.range) else { continue }
            let box = selection.bounds(for: page)
            guard !box.isNull, !box.isInfinite, !box.isEmpty else { continue }
            let dx = max(box.minX - point.x, 0, point.x - box.maxX)
            let dy = max(box.minY - point.y, 0, point.y - box.maxY)
            let distance = hypot(dx, dy), area = box.width * box.height
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance || (distance == best!.distance && area < best!.area) {
                best = (distance, area, selection)
            }
        }
        return best?.selection
    }
}
