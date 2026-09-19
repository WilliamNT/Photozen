import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FolderIconProvider {
    static let shared = FolderIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var photosAppIcon: NSImage?
    private var photoBoothAppIcon: NSImage?

    private init() {
        cache.countLimit = 250

        // Resolve Apple Photos application icon
        if let photosURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            let icon = NSWorkspace.shared.icon(forFile: photosURL.path)
            icon.size = NSSize(width: 32, height: 32)
            self.photosAppIcon = icon
        } else if FileManager.default.fileExists(atPath: "/System/Applications/Photos.app") {
            let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Photos.app")
            icon.size = NSSize(width: 32, height: 32)
            self.photosAppIcon = icon
        }

        // Resolve Apple Photo Booth application icon
        if let pbURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.PhotoBooth") {
            let icon = NSWorkspace.shared.icon(forFile: pbURL.path)
            icon.size = NSSize(width: 32, height: 32)
            self.photoBoothAppIcon = icon
        } else if FileManager.default.fileExists(atPath: "/System/Applications/Photo Booth.app") {
            let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Photo Booth.app")
            icon.size = NSSize(width: 32, height: 32)
            self.photoBoothAppIcon = icon
        }
    }

    /// Resolves the authentic macOS icon for a root FolderLocation
    func icon(for location: FolderLocation) -> NSImage {
        let key = location.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let resolved = resolveIcon(path: location.path, name: location.name, kind: location.kind)
        cache.setObject(resolved, forKey: key)
        return resolved
    }

    /// Resolves the authentic macOS icon for any directory path or URL
    func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let name = URL(fileURLWithPath: path).lastPathComponent
        let resolved = resolveIcon(path: path, name: name, kind: nil)
        cache.setObject(resolved, forKey: key)
        return resolved
    }

    private func resolveIcon(path: String, name: String, kind: LocationKind?) -> NSImage {
        let lowerPath = path.lowercased()
        let lowerName = name.lowercased()

        // 1. Apple Photos Library (.photoslibrary, .photolibrary, .aplibrary)
        if lowerPath.hasSuffix(".photoslibrary") || lowerName.hasSuffix(".photoslibrary")
            || lowerPath.hasSuffix(".photolibrary") || lowerName.contains("photos library") {
            if let photosIcon = photosAppIcon {
                return photosIcon
            }
        }

        // 2. Apple Photo Booth Library
        if lowerPath.contains("photo booth library") || lowerName.contains("photo booth") {
            if let pbIcon = photoBoothAppIcon {
                return pbIcon
            }
        }

        // 3. Native macOS Workspace Icon for path (Finder icon, special Pictures/Desktop/Downloads badges, USB/SD card icons)
        if FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 32, height: 32)
            return icon
        }

        // 4. Kind-based fallback for disconnected or unmounted paths
        if let kind {
            switch kind {
            case .removableDisk:
                if let img = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil) {
                    return img
                }
            case .networkShare:
                if let img = NSImage(systemSymbolName: "network", accessibilityDescription: nil) {
                    return img
                }
            case .builtIn:
                if let img = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: nil) {
                    return img
                }
            case .userFolder:
                break
            }
        }

        return defaultFolderIcon()
    }

    private func defaultFolderIcon() -> NSImage {
        let key = "__generic_folder_icon__" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 32, height: 32)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
