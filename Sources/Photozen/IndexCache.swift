import CryptoKit
import Foundation

struct CachedDirectorySnapshot: Codable, Equatable, Sendable {
    var path: String
    var modificationDate: Date?
    var entryCount: Int
}

struct CachedIndex: Codable, Equatable, Sendable {
    var rootPath: String
    var lastScanned: Date
    var items: [ImageItem]
    var directorySnapshots: [CachedDirectorySnapshot]
}

actor IndexCache {
    static let shared = IndexCache()

    private var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Photozen/Indexes", isDirectory: true)
    }

    private func cacheURL(for rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let hexString = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hexString).json")
    }

    func load(rootPath: String) async -> CachedIndex? {
        let url = cacheURL(for: rootPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedIndex.self, from: data)
    }

    func save(_ index: CachedIndex) async {
        let dir = cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = cacheURL(for: index.rootPath)
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache save failure is non-fatal; the next scan will just be full.
        }
    }

    func remove(rootPath: String) async {
        let url = cacheURL(for: rootPath)
        try? FileManager.default.removeItem(at: url)
    }
}
