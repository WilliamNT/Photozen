import Foundation
import SwiftUI

@MainActor
final class FolderNode: ObservableObject, Identifiable {
    let id: String
    let url: URL
    let name: String
    let depth: Int
    let isRoot: Bool
    let rootLocationID: UUID
    let kind: LocationKind
    let isVolatile: Bool
    @Published var status: ItemStatus

    @Published var children: [FolderNode] = []
    @Published var imageItems: [ImageItem] = []
    @Published var isExpanded = false
    @Published var isLoading = false
    var childrenLoaded = false

    init(url: URL, depth: Int, isRoot: Bool, rootLocationID: UUID, kind: LocationKind, isVolatile: Bool, status: ItemStatus) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.depth = depth
        self.isRoot = isRoot
        self.rootLocationID = rootLocationID
        self.kind = kind
        self.isVolatile = isVolatile
        self.status = status
    }

    var systemImage: String {
        if status == .missing { return "externaldrive.badge.exclamationmark" }
        if isRoot { return kind.symbolName }
        return "folder"
    }

    func loadChildren() async {
        guard !childrenLoaded else { return }
        isLoading = true
        defer { isLoading = false }

        let parentURL = url
        let depth = self.depth
        let rootLocationID = self.rootLocationID
        let kind = self.kind
        let isVolatile = self.isVolatile
        let status = self.status

        // Enumerate immediate subdirectories and image files
        let (loadedSubdirs, loadedImages): ([(String, String)], [ImageItem]) = await Task.detached(priority: .userInitiated) { () -> ([(String, String)], [ImageItem]) in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: parentURL,
                includingPropertiesForKeys: Array(ImageScanner.scanKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []

            var subdirs: [(String, String)] = []
            var images: [ImageItem] = []

            for child in contents {
                guard let values = try? child.resourceValues(forKeys: ImageScanner.scanKeys) else { continue }
                if values.isSymbolicLink == true { continue }

                let childPath = child.standardizedFileURL.path

                if values.isDirectory == true {
                    if ImageScanner.shouldSkipDirectory(name: child.lastPathComponent, path: childPath, isPackage: values.isPackage == true) {
                        continue
                    }
                    subdirs.append((child.lastPathComponent, childPath))
                } else if values.isRegularFile == true {
                    if let item = ImageScanner.makeItem(url: child, values: values) {
                        images.append(item)
                    }
                }
            }

            subdirs.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            images.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            return (subdirs, images)
        }.value

        children = loadedSubdirs.map { name, path in
            FolderNode(
                url: URL(fileURLWithPath: path, isDirectory: true),
                depth: depth + 1,
                isRoot: false,
                rootLocationID: rootLocationID,
                kind: kind,
                isVolatile: isVolatile,
                status: status
            )
        }
        imageItems = loadedImages
        childrenLoaded = true
    }

    func refreshAvailability() {
        let reachable = (try? url.checkResourceIsReachable()) ?? false
        status = reachable ? .available : .missing
        for child in children {
            child.refreshAvailability()
        }
    }
}
