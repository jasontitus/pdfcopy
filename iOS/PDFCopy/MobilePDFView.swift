import SwiftUI
import PDFKit
import PDFCopyCore

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
        model.attach(view)
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

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: DocumentModel
        private var offsets: NSKeyValueObservation?
        private var zoom: NSKeyValueObservation?
        private weak var pdf: PDFView?
        private var wordTap: UITapGestureRecognizer?
        private weak var scroll: UIScrollView?
        init(model: DocumentModel) { self.model = model }
        func observe(_ view: PDFView) {
            pdf = view
            let tap = UITapGestureRecognizer(target: self, action: #selector(selectWord))
            tap.cancelsTouchesInView = false; tap.delegate = self
            view.addGestureRecognizer(tap); wordTap = tap
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
        @objc private func selectWord(_ gesture: UITapGestureRecognizer) {
            guard let view = pdf, !model.selectingRegion, view.document?.allowsCopying == true else { return }
            let location = gesture.location(in: view)
            guard let page = view.page(for: location, nearest: false) else { return }
            let point = view.convert(location, to: page)
            if page.annotations.contains(where: { $0.bounds.contains(point) }) { return }
            guard let selection = PreciseTextSelection.word(on: page, at: point, tolerance: 5 / max(view.scaleFactor, 0.1)) else { return }
            // Let PDFKit finish its single-tap handling before setting the exact range.
            Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard let self, let view, view.document === page.document else { return }
                view.setCurrentSelection(selection, animate: false)
                self.model.selectionChanged()
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func stop() {
            if let wordTap { pdf?.removeGestureRecognizer(wordTap) }
            offsets = nil; zoom = nil; NotificationCenter.default.removeObserver(self)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
