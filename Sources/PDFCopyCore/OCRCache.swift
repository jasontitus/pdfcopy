import Foundation
import CryptoKit

/// Disposable, device-local derived PDFs. Keys contain no filenames; originals are untouched.
public actor OCRCache {
    public struct Lookup: Sendable {
        public let key: String
        public let epoch: UInt64
        public let data: Data?
    }
    public static let shared = OCRCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PDFCopy/Recognized-v3", isDirectory: true))
    private let directory: URL
    private let maxBytes: Int
    private let maxEntries: Int
    private let lifetime: TimeInterval
    private var epoch: UInt64 = 0
    public init(directory: URL, maxBytes: Int = 256 * 1024 * 1024, maxEntries: Int = 20,
                lifetime: TimeInterval = 30 * 24 * 60 * 60) {
        self.directory = directory; self.maxBytes = maxBytes
        self.maxEntries = maxEntries; self.lifetime = lifetime
    }
    public func lookup(source: Data) -> Lookup {
        let signature = "PDFCopy-OCR-v3-\(ProcessInfo.processInfo.operatingSystemVersionString)".data(using: .utf8)!
        var hasher = SHA256(); hasher.update(data: signature); hasher.update(data: source)
        let key = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(key).appendingPathExtension("pdf")
        try? prune()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let data = size > 0 && size <= maxBytes ? try? Data(contentsOf: url) : nil
        if data != nil { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return Lookup(key: key, epoch: epoch, data: data)
    }
    public func store(_ data: Data, for lookup: Lookup) throws {
        guard lookup.epoch == epoch, data.count <= maxBytes else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let file = directory.appendingPathComponent(lookup.key).appendingPathExtension("pdf")
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try prune()
    }
    public func clear() throws {
        // In-flight work using an earlier lookup may not silently recreate cleared files.
        epoch &+= 1
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    public func size() -> Int { (try? entries().reduce(0) { $0 + $1.size }) ?? 0 }
    private func entries() throws -> [(url: URL, size: Int, date: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "pdf" }.map {
                let values = try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return ($0, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.date > $1.date }
    }
    private func prune() throws {
        var total = 0, count = 0
        for entry in try entries() {
            if Date().timeIntervalSince(entry.date) > lifetime || count >= maxEntries || total + entry.size > maxBytes {
                try FileManager.default.removeItem(at: entry.url)
            } else { total += entry.size; count += 1 }
        }
    }
}
