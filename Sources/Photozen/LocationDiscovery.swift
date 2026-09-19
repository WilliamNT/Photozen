import AppKit
import Foundation
import UniformTypeIdentifiers

enum LocationDiscovery {
    static func makeLocation(for url: URL) throws -> FolderLocation {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let kind = classify(url: standardized)
        return FolderLocation(
            id: UUID(),
            path: standardized.path,
            name: standardized.lastPathComponent,
            kind: kind,
            isVolatile: isPotentiallyVolatile(url: standardized),
            status: .available,
            lastSeen: Date()
        )
    }

    static func classify(url: URL) -> LocationKind {
        let values = try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsEjectableKey])
        let isRoot = values?.volumeIsRootFileSystem ?? false
        let isLocal = values?.volumeIsLocal ?? false
        let isEjectable = values?.volumeIsEjectable ?? false

        if !isLocal { return .networkShare }
        if isRoot { return .builtIn }
        if isEjectable { return .removableDisk }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? home
        if url.path.hasPrefix(home) || url.path.hasPrefix(documents) { return .userFolder }
        return .removableDisk
    }

    static func isPotentiallyVolatile(url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey, .volumeIsEjectableKey])
        if values?.volumeIsRootFileSystem == true { return false }
        return true
    }
}
