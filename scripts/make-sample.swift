import AppKit
import CoreText
import PDFKit

// A fully local smoke-test document: native, scanned, and mixed pages.
func draw(_ text: String, y: CGFloat, in context: CGContext) {
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 54, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])), context)
}
let output = NSMutableData()
var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdf = CGContext(consumer: CGDataConsumer(data: output)!, mediaBox: &bounds, nil)!
for kind in ["Native text", "Scanned text", "Mixed content"] {
    pdf.beginPDFPage(nil)
    if kind != "Native text" {
        let bitmap = CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
        bitmap.scaleBy(x: 2, y: 2)
        draw("This sentence is an image until OCR runs.", y: 570, in: bitmap)
        draw("Double-click a word, then copy it anywhere.", y: 530, in: bitmap)
        draw("Punctuation survives: apples, pears & oranges.", y: 490, in: bitmap)
        pdf.draw(bitmap.makeImage()!, in: bounds)
    }
    if kind != "Scanned text" {
        draw("PDFCopy / \(kind)", y: 700, in: pdf)
        draw("This sentence already has selectable text.", y: 650, in: pdf)
    }
    pdf.endPDFPage()
}
pdf.closePDF()
let path = CommandLine.arguments.dropFirst().first ?? "dist/Sample.pdf"
try (output as Data).write(to: URL(fileURLWithPath: path))
print(path)
