import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct PDFCopyIOSApp: App {
    var body: some Scene {
        WindowGroup { MobileContentView() }
    }
}

struct MobileContentView: View {
    @StateObject private var model = DocumentModel()
    @State private var importing = false
    @State private var resumeOnActive = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.needsPassword {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.doc").font(.largeTitle)
                        Text("This PDF is password protected")
                        SecureField("PDF password", text: $model.password)
                            .textFieldStyle(.roundedBorder).onSubmit { model.unlock() }
                        Button("Unlock") { model.unlock() }.buttonStyle(.borderedProminent)
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.document != nil {
                    if model.showsSearch {
                        PDFSearchBar(search: model.search, recognizing: model.running) { model.showsSearch = false }
                        Divider()
                    }
                    MobilePDFView(model: model)
                    HStack {
                        Button { model.movePage(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(model.currentPage == 0).accessibilityLabel("Previous page")
                        Text("\(model.currentPage + 1) / \(model.pageCount)").monospacedDigit()
                        Button { model.movePage(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(model.currentPage >= model.pageCount - 1).accessibilityLabel("Next page")
                        Spacer()
                        Button { model.copySelection() } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .disabled(!model.hasSelection)
                    }.padding(.horizontal).padding(.vertical, 8)
                } else {
                    ContentUnavailableView {
                        Label("Your PDF. Your words.", systemImage: "doc.text.viewfinder")
                    } description: {
                        Text("Open a PDF, touch and hold text to select it, then copy it anywhere. Text recognition stays on your device.")
                    } actions: {
                        Button("Open PDF…") { importing = true }.buttonStyle(.borderedProminent)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text(model.status).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                    if model.running {
                        ProgressView().controlSize(.small)
                        Button("Pause") { model.toggleProcessing() }.font(.caption)
                    } else if model.processed < model.pageCount, !model.needsPassword, model.document?.allowsCopying == true {
                        Button("Resume") { model.toggleProcessing() }.font(.caption)
                    }
                }.padding(10)
            }
            .navigationTitle(model.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: { Label("Open PDF", systemImage: "folder") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.document != nil, !model.needsPassword {
                        Button { model.showSearch() } label: { Label("Search", systemImage: "magnifyingglass") }
                        Menu {
                            Button("Fit Page") { model.pdfView?.autoScales = true }
                            Button("Recognize Again") { model.retryPage() }.disabled(model.document?.allowsCopying != true)
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): model.open(url)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .onOpenURL { model.open($0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                resumeOnActive = model.running
                if model.running { model.toggleProcessing() }
            } else if phase == .active, resumeOnActive {
                resumeOnActive = false
                if !model.running { model.toggleProcessing() }
            }
        }
        .alert("PDFCopy", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
