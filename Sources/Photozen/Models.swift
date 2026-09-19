import AppKit
import CryptoKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum LocationKind: String, Codable, Sendable {
    case builtIn
    case removableDisk
    case networkShare
    case userFolder

    var label: String {
        switch self {
        case .builtIn: "Built-in Disk"
        case .removableDisk: "Removable Disk"
        case .networkShare: "Network Share"
        case .userFolder: "Folder"
        }
    }

    var symbolName: String {
        switch self {
        case .builtIn: "internaldrive.fill"
        case .removableDisk: "externaldrive.connected.to.line.below"
        case .networkShare: "network"
        case .userFolder: "folder.fill"
        }
    }
}

enum ItemStatus: String, Codable, Sendable, Equatable {
    case available
    case missing
}

struct FolderLocation: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var path: String
    var name: String
    var kind: LocationKind
    var isVolatile: Bool
    var status: ItemStatus
    var lastSeen: Date?

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct ImageItem: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: UUID
    let path: String
    let name: String
    let parentPath: String
    let size: Int64
    let modificationDate: Date?
    let typeIdentifier: String
    let isSwiftRenderable: Bool
    let isMovieLike: Bool
    var status: ItemStatus = .available

    var url: URL { URL(fileURLWithPath: path) }
    var folderName: String { URL(fileURLWithPath: parentPath).lastPathComponent }
}

extension ImageItem {
    static func stableID(for path: String) -> UUID {
        let digest = SHA256.hash(data: Data(path.utf8))
        let bytes = Array(digest.prefix(16))
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid
    }
}

enum SidebarSelection: Hashable, Identifiable, Sendable {
    case location(UUID)
    case subfolder(locationID: UUID, path: String)
    case image(locationID: UUID, item: ImageItem)

    var id: String {
        switch self {
        case .location(let uuid):
            return "loc-\(uuid.uuidString)"
        case .subfolder(let uuid, let path):
            return "sub-\(uuid.uuidString)-\(path)"
        case .image(let uuid, let item):
            return "img-\(uuid.uuidString)-\(item.id.uuidString)"
        }
    }
}

@MainActor
enum ImageClipboard {
    static func copyImage(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var objects: [NSPasteboardWriting] = [url as NSURL]
        if let image = NSImage(contentsOf: url) {
            objects.append(image)
        }
        pasteboard.writeObjects(objects)
    }
}

struct ImageFilter: Equatable, Sendable {
    var text = ""
    var subfolderPath: String? = nil
    var onlySwiftRenderable = false
    var onlyVolatileLocations = false
    var sortByDate = true
    var zoomLevel: Double = 1.0

    func matches(_ item: ImageItem) -> Bool {
        if let subfolderPath {
            if !item.path.hasPrefix(subfolderPath) { return false }
        }
        if onlySwiftRenderable, !item.isSwiftRenderable { return false }
        if text.isEmpty { return true }
        return item.name.localizedCaseInsensitiveContains(text)
            || item.folderName.localizedCaseInsensitiveContains(text)
    }
}

struct DateGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let items: [ImageItem]

    static func == (lhs: DateGroup, rhs: DateGroup) -> Bool {
        lhs.id == rhs.id && lhs.items == rhs.items
    }
}
