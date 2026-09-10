import XCTest
@testable import PDFCopyCore

final class OCRCacheTests: XCTestCase {
    func testContentKeyRoundTripAndClearRejectsInflightWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = OCRCache(directory: folder)
        let source = Data("source PDF contents".utf8), output = Data("recognized PDF contents".utf8)
        let first = await cache.lookup(source: source)
        XCTAssertNil(first.data)
        try await cache.store(output, for: first)
        let hit = await cache.lookup(source: source)
        XCTAssertEqual(hit.data, output)
        let changed = await cache.lookup(source: Data("changed PDF contents".utf8))
        XCTAssertNotEqual(hit.key, changed.key); XCTAssertNil(changed.data)
        let file = folder.appendingPathComponent(first.key).appendingPathExtension("pdf")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try await cache.clear()
        try await cache.store(output, for: hit)
        let cleared = await cache.lookup(source: source)
        XCTAssertNil(cleared.data, "A queued write must not recreate explicitly cleared data")
    }
    func testBudgetAndExpiration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = OCRCache(directory: folder, maxBytes: 10, maxEntries: 2, lifetime: 60)
        let a = await cache.lookup(source: Data("a".utf8))
        try await cache.store(Data(repeating: 1, count: 6), for: a)
        let b = await cache.lookup(source: Data("b".utf8))
        try await cache.store(Data(repeating: 2, count: 6), for: b)
        let size = await cache.size(); XCTAssertLessThanOrEqual(size, 10)
        let file = folder.appendingPathComponent(b.key).appendingPathExtension("pdf")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: file.path)
        let expired = await cache.lookup(source: Data("b".utf8)); XCTAssertNil(expired.data)
        try await cache.store(Data(repeating: 0, count: 20), for: b)
        let oversize = await cache.lookup(source: Data("b".utf8)); XCTAssertNil(oversize.data)
    }
}
