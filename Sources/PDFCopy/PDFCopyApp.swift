import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@main
struct PDFCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = DocumentModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 680, minHeight: 480)
                .onAppear { delegate.model = model }
                .onOpenURL { model.open($0) }
        }
        .defaultSize(width: 1040, height: 820)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.showSearch() }.keyboardShortcut("f").disabled(model.document == nil || model.needsPassword)
                Button("Find Next") { model.search.move(1) }.keyboardShortcut("g")
                Button("Find Previous") { model.search.move(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { model.chooseFile() }.keyboardShortcut("o")
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DocumentModel? {
        didSet { openQueuedFile() }
    }
    private var queuedURL: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if queuedURL == nil, let path = CommandLine.arguments.dropFirst().first,
           path.lowercased().hasSuffix(".pdf") {
            queuedURL = URL(fileURLWithPath: path)
        }
        openQueuedFile()
    }
    private func openQueuedFile() {
        guard let model, let url = queuedURL else { return }
        queuedURL = nil
        model.open(url)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model { model.open(url) } else { queuedURL = url }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var model: DocumentModel
    var body: some View {
        VStack(spacing: 0) {
            if model.document != nil, !model.needsPassword {
                if model.showsSearch {
                    PDFSearchBar(search: model.search, recognizing: model.running) { model.showsSearch = false }
                    Divider()
                }
                PageReadinessView(model: model)
                NativePDFView(model: model).overlay { RegionSelectionOverlay(model: model) }
            } else if model.needsPassword {
                VStack(spacing: 16) {
                    Image(systemName: "lock.doc").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("This PDF is password protected").font(.title2)
                    SecureField("PDF password", text: $model.password)
                        .textFieldStyle(.roundedBorder).frame(width: 280).onSubmit { model.unlock() }
                    Button("Unlock") { model.unlock() }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "doc.text.viewfinder").font(.system(size: 58, weight: .light)).foregroundStyle(.tint)
                    Text("Your PDF. Your words.").font(.largeTitle.weight(.semibold))
                    Text("Open a PDF, select text, and copy it anywhere.")
                        .font(.title3).foregroundStyle(.secondary)
                    Button("Open PDF…") { model.chooseFile() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Or drop a PDF here\nText recognition runs entirely on your Mac.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text(model.status).font(.caption).lineLimit(1)
                Spacer()
                if model.running {
                    ProgressView(value: Double(model.processed), total: Double(max(1, model.pageCount))).frame(width: 90)
                    Button("Pause") { model.toggleProcessing() }.font(.caption)
                } else if model.processed < model.pageCount, !model.openingCache, !model.needsPassword, model.document?.allowsCopying == true {
                    Button("Resume") { model.toggleProcessing() }.font(.caption)
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .sheet(isPresented: $model.showsRegionResult, onDismiss: { model.dismissRegionResult() }) { RegionResultView(model: model) }
        .sheet(isPresented: $model.showsCacheSettings) { OCRCacheSettings(model: model) }
        .navigationTitle(model.fileName)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.chooseFile() } label: { Label("Open PDF", systemImage: "folder") }
                if model.pageCount > 0, !model.needsPassword {
                    Button { model.movePage(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.currentPage == 0).help("Previous page")
                    Text("\(model.currentPage + 1) / \(model.pageCount)").monospacedDigit()
                    Button { model.movePage(1) } label: { Image(systemName: "chevron.right") }.disabled(model.currentPage >= model.pageCount - 1).help("Next page")
                }
            }
            ToolbarItemGroup {
                Button { model.showsCacheSettings = true } label: { Label("Saved text", systemImage: "internaldrive") }
                if model.document != nil, !model.needsPassword {
                    Button { model.showSearch() } label: { Label("Search", systemImage: "magnifyingglass") }
                    Button { model.pdfView?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                    Button { model.pdfView?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                    Button("Fit") { model.pdfView?.autoScales = true }.help("Fit page to window")
                    Menu("Recognize") {
                        Button("Recognize Area…") { model.beginRegionSelection() }
                        Button("Recognize Selection") { model.recognizeSelectedArea() }.disabled(!model.hasSelection)
                        Button("Recognize Whole Page Again") { model.retryPage() }
                    }.disabled(model.document?.allowsCopying != true)
                    Button("Recognize Again") { model.retryPage() }
                        .disabled(model.document?.allowsCopying != true)
                        .help("Rebuild this page’s text from its appearance if existing text copies incorrectly")
                    Button { model.copySelection() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(!model.hasSelection)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "pdf" else { return false }
            model.open(url); return true
        }
        .alert("PDFCopy", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct NativePDFView: NSViewRepresentable {
    @ObservedObject var model: DocumentModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.document = model.document
        view.layoutDocumentView()
        model.attach(view)
        model.search.attach(document: model.document, view: view)
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== model.document { view.document = model.document; view.autoScales = true }
        model.search.attach(document: model.document, view: view)
        context.coordinator.observeScrolling(in: view)
    }
    @MainActor final class Coordinator: NSObject {
        let model: DocumentModel
        var observers: [NSObjectProtocol] = []
        private weak var observedScrollView: NSScrollView?
        init(model: DocumentModel) { self.model = model; super.init() }
        func observe(_ view: PDFView) {
            observeScrolling(in: view)
            observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let page = view?.currentPage, let doc = view?.document else { return }
                    let index = doc.index(for: page)
                    if index != NSNotFound { self.model.currentPage = index }
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model.selectionChanged() }
            })
        }
        func observeScrolling(in view: PDFView) {
            guard let scroll = view.documentView?.enclosingScrollView, observedScrollView !== scroll else { return }
            let center = NotificationCenter.default
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification,
                         NSScrollView.didEndLiveScrollNotification, NSView.boundsDidChangeNotification] {
                center.removeObserver(self, name: name, object: nil)
            }
            observedScrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(scrollBegan), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrollMoved), name: NSScrollView.didLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrollMoved), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        @objc private func scrollBegan(_ notification: Notification) { model.scrollActivity(began: true) }
        @objc private func scrollMoved(_ notification: Notification) { model.scrollActivity() }
        @objc private func scrollEnded(_ notification: Notification) { model.scrollActivity(ended: true) }
        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            NotificationCenter.default.removeObserver(self)
        }
    }
}
