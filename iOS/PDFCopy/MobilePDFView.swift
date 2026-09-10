import SwiftUI
import PDFKit

extension PDFView {
    var contentScrollView: UIScrollView? {
        var ancestor = documentView?.superview
        while let current = ancestor, current !== self {
            if let scroll = current as? UIScrollView { return scroll }
            ancestor = current.superview
        }
        return nil
    }
}

struct MobilePDFView: UIViewRepresentable {
    @ObservedObject var model: DocumentModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .secondarySystemBackground
        view.document = model.document
        view.layoutDocumentView()
        model.pdfView = view
        model.search.attach(document: model.document, view: view)
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== model.document { view.document = model.document; view.autoScales = true }
        model.search.attach(document: model.document, view: view)
        context.coordinator.observeScrolling(view)
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        let model: DocumentModel
        private var offsets: NSKeyValueObservation?
        private var zoom: NSKeyValueObservation?
        private weak var scroll: UIScrollView?
        init(model: DocumentModel) { self.model = model }
        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            observeScrolling(view)
        }
        func observeScrolling(_ view: PDFView) {
            guard let current = view.contentScrollView, current !== scroll else { return }
            scroll = current
            offsets = current.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                // PDFKit updates its UIKit view hierarchy on the main thread.
                MainActor.assumeIsolated { self?.model.scrollActivity() }
            }
            zoom = current.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.model.scrollActivity() }
            }
        }
        @objc private func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let page = view.currentPage, let doc = view.document else { return }
            let index = doc.index(for: page)
            if index != NSNotFound { model.currentPage = index }
        }
        @objc private func selectionChanged(_ notification: Notification) { model.selectionChanged() }
        func stop() { offsets = nil; zoom = nil; NotificationCenter.default.removeObserver(self) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
