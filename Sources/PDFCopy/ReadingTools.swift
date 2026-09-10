import SwiftUI

struct PageReadinessView: View {
    @ObservedObject var model: DocumentModel
    var body: some View {
        if model.pageCount > 0, !model.needsPassword {
            HStack(alignment: .center) {
                Image(systemName: model.readyPages.contains(model.currentPage) ? "checkmark.circle.fill" : "text.viewfinder")
                    .foregroundStyle(model.readyPages.contains(model.currentPage) ? Color.green : Color.orange)
                Text(model.pageReadiness).font(.caption).accessibilityIdentifier("pageReadiness")
                Spacer(minLength: 0)
                if model.canApplyText {
                    Button("Use improved text") { model.applyImprovedText() }.font(.caption)
                }
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }
    }
}

struct RegionSelectionOverlay: View {
    @ObservedObject var model: DocumentModel
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    var body: some View {
        if model.selectingRegion {
            GeometryReader { _ in
                ZStack(alignment: .top) {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            start = value.startLocation; end = value.location
                        }.onEnded { value in
                            let box = CGRect(x: min(value.startLocation.x, value.location.x),
                                y: min(value.startLocation.y, value.location.y),
                                width: abs(value.location.x - value.startLocation.x),
                                height: abs(value.location.y - value.startLocation.y))
                            start = nil; end = nil; model.recognizeArea(inView: box)
                        })
                    if let start, let end {
                        Rectangle().fill(Color.accentColor.opacity(0.15))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: abs(end.x - start.x), height: abs(end.y - start.y))
                            .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                            .allowsHitTesting(false)
                    }
                    HStack {
                        Text("Drag around text on one page").font(.callout)
                        Button("Cancel") { model.cancelRegionSelection() }
                    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(8)
                }
            }.accessibilityLabel("Draw an area to recognize")
        }
    }
}

struct RegionResultView: View {
    @ObservedObject var model: DocumentModel
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Text from area").font(.title2.bold())
                Spacer()
                Button("Done") { model.dismissRegionResult() }
            }
            if model.recognizingRegion {
                ProgressView("Recognizing on this device…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(model.regionMessage).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(model.regionText).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if !model.regionText.isEmpty {
                            Text("Copy a word").font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading) {
                                ForEach(Array(model.regionText.split(whereSeparator: \.isWhitespace).enumerated()), id: \.offset) { _, word in
                                    Button(String(word)) { model.copyText(String(word)); copied = true }
                                        .buttonStyle(.bordered).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("Copy all text") { model.copyText(model.regionText); copied = true }
                        .buttonStyle(.borderedProminent).disabled(model.regionText.isEmpty)
                    if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("This preview does not change your PDF.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        #if os(macOS)
        .frame(width: 560, height: 460)
        #endif
    }
}

struct OCRCacheSettings: View {
    @ObservedObject var model: DocumentModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Saved text").font(.title2.bold())
                Spacer()
                Button("Done") { model.showsCacheSettings = false }
            }
            Toggle("Remember OCR on this device", isOn: Binding(get: { model.remembersOCR }, set: { model.setRemembersOCR($0) }))
            Text("Keep recognized copies locally for faster reopening. Copies may contain sensitive document content. They are excluded from backups; password-protected PDFs are never saved. Turning this off clears saved copies.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Stored: \(ByteCountFormatter.string(fromByteCount: Int64(model.cacheBytes), countStyle: .file)) · Up to 256 MB / 20 PDFs")
                .font(.caption)
            Button("Clear saved OCR") { model.clearCachedOCR() }.buttonStyle(.bordered)
            Text(model.cacheMessage).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(20).onAppear { model.refreshCacheSize() }
        #if os(macOS)
        .frame(width: 500, height: 320)
        #endif
    }
}
