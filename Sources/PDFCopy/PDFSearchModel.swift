import SwiftUI
import PDFKit

/// Search highlights are independent of the copy selection, so OCR can keep progressing.
@MainActor
final class PDFSearchModel: ObservableObject {
    @Published var focusRequest = UUID()
    @Published var query = "" { didSet { if query != oldValue { schedule(navigate: true) } } }
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var searching = false
    private weak var document: PDFDocument?
    private weak var view: PDFView?
    private var task: Task<Void, Never>?
    private var revision = UUID()

    var countLabel: String {
        if searching { return "Searching…" }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        return matches.isEmpty ? "No matches" : "\(currentIndex + 1) of \(matches.count)"
    }

    func attach(document: PDFDocument?, view: PDFView) {
        self.view = view
        guard self.document !== document else { return }
        self.document = document
        schedule(navigate: false)
    }

    func reset() {
        task?.cancel(); revision = UUID()
        query = ""
        matches = []; currentIndex = -1; searching = false
        view?.highlightedSelections = nil
        document = nil
    }

    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + delta + matches.count) % matches.count
        highlight()
        view?.go(to: matches[currentIndex])
    }

    private func schedule(navigate: Bool) {
        task?.cancel()
        let token = UUID(); revision = token
        let oldIndex = currentIndex
        matches = []; currentIndex = -1
        view?.highlightedSelections = nil
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let document, !document.isLocked else { searching = false; return }
        searching = true
        task = Task { [weak self, document] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            var found: [PDFSelection] = []
            for index in 0..<document.pageCount {
                guard !Task.isCancelled else { return }
                if let page = document.page(at: index), let string = page.string {
                    let text = string as NSString
                    var offset = 0
                    while offset < text.length {
                        let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                               range: NSRange(location: offset, length: text.length - offset))
                        guard range.location != NSNotFound, range.length > 0 else { break }
                        if let selection = page.selection(for: range) { found.append(selection) }
                        offset = NSMaxRange(range)
                    }
                }
                // Keep scrolling, typing, and cancellation responsive between pages.
                await Task.yield()
            }
            guard let self, !Task.isCancelled, self.revision == token, self.document === document else { return }
            self.matches = found
            self.currentIndex = found.isEmpty ? -1 : (navigate ? 0 : min(max(0, oldIndex), found.count - 1))
            self.searching = false
            self.highlight()
            if navigate, let first = found.first { self.view?.go(to: first) }
        }
    }

    private func highlight() {
        for (index, match) in matches.enumerated() {
            #if os(macOS)
            match.color = (index == currentIndex ? NSColor.systemOrange : .systemYellow).withAlphaComponent(0.45)
            #else
            match.color = (index == currentIndex ? UIColor.systemOrange : .systemYellow).withAlphaComponent(0.45)
            #endif
        }
        view?.highlightedSelections = matches
    }
}

struct PDFSearchBar: View {
    @ObservedObject var search: PDFSearchModel
    var recognizing: Bool
    var close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in PDF", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { search.move(1) }
                    .accessibilityIdentifier("pdfSearchField")
                Button { search.move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(search.matches.isEmpty).accessibilityLabel("Previous match")
                Button { search.move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(search.matches.isEmpty).accessibilityLabel("Next match")
                Button { search.query = ""; close() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close search")
            }
            HStack {
                Text(search.countLabel).monospacedDigit().accessibilityIdentifier("searchCount")
                if recognizing { Text("Results update as text is recognized.") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(10)
        .task { await Task.yield(); focused = true }
        .onChange(of: search.focusRequest) { _, _ in focused = true }
        #if os(macOS)
        .onExitCommand { search.query = ""; close() }
        #endif
    }
}
