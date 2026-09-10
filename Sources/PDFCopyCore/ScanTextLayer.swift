import CoreGraphics

/// Be conservative: only automatically discard embedded text when every text-showing
/// operator is invisible and the page paints an image. Uninspected Form XObjects
/// disable this shortcut; visible/mixed documents retain their original content.
enum ScanTextLayer {
    private final class State {
        var mode: CGPDFInteger = 0
        var stack: [CGPDFInteger] = []
        var hidden = false
        var visible = false
        var image = false
        var unknown = false
    }

    static func isImageWithOnlyInvisibleText(_ page: CGPDFPage) -> Bool {
        let state = State()
        guard let table = CGPDFOperatorTableCreate() else { return false }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            state.stack.append(state.mode)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            if let mode = state.stack.popLast() { state.mode = mode } else { state.unknown = true }
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { state.mode = mode } else { state.unknown = true }
        }
        for operation in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, operation) { _, info in
                guard let info else { return }
                let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
                if state.mode == 3 { state.hidden = true } else { state.visible = true }
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let resource = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name)
            else { state.unknown = true; return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(resource, .stream, &stream), let stream else { state.unknown = true; return }
            var subtype: UnsafePointer<CChar>?
            guard let dictionary = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype
            else { state.unknown = true; return }
            if String(cString: subtype) == "Image" { state.image = true } else { state.unknown = true }
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        return CGPDFScannerScan(scanner) && state.hidden && !state.visible && state.image && !state.unknown
    }
}
