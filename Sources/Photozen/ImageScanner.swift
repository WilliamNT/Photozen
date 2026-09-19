import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ImageScanner {
    private static let customImageExtensions: Set<String> = [
        "raf", "orf", "rw2", "raw", "cr2", "cr3", "arw", "dng", "nef", "nrw",
        "srw", "pef", "ptx", "3fr", "fff", "iiq", "mos", "mrw", "x3f", "rwl",
        "jxl", "avif", "heif", "heifs", "xcf", "pcx", "tga", "psd", "dds",
        "svg", "svgz", "exr", "dpx", "cin", "wbmp", "fits", "ppm", "pgm", "pbm", "pnm"
    ]

    /// Directory names that are ignored during scanning (caches, thumbnails, trash, dev).
    private static let excludedDirectoryNames: Set<String> = [
        "@eadir", ".@__thumb", ".thumbnails", ".cache", "thumbnails",
        "previews", ".trash", ".trashes", ".temporaryitems",
        ".spotlight-v100", ".fseventsd", "node_modules", ".git", ".svn", ".hg"
    ]

    /// File package extensions that represent photo libraries containing user originals.
    static let photoLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary"
    ]

    /// Maximum number of directories enumerated concurrently.
    private static let enumerationConcurrency = 8

    /// URL resource keys prefetched in a single batch during directory enumeration.
    static let scanKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        .fileSizeKey, .contentModificationDateKey, .contentTypeKey
    ]

    private struct EnumerationResult: Sendable {
        var subdirectories: [String]
        var items: [ImageItem]
        var enumerationFailed: Bool
    }

    // MARK: - Full Scan

    /// Recursively scans a folder location for supported images.
    func scan(
        location: FolderLocation,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [ImageItem] {
        let rootPath = location.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        var collected: [ImageItem] = []
        var seenPaths = Set<String>()
        var pending = [rootPath]

        while !pending.isEmpty {
            if Task.isCancelled { throw CancellationError() }

            let batchCount = min(Self.enumerationConcurrency, pending.count)
            let batch = Array(pending.suffix(batchCount))
            pending.removeLast(batchCount)

            let listings = await withTaskGroup(of: EnumerationResult.self) { group in
                for path in batch {
                    group.addTask { Self.enumerate(directoryPath: path) }
                }
                var results: [EnumerationResult] = []
                results.reserveCapacity(batchCount)
                for await result in group {
                    results.append(result)
                }
                return results
            }

            if Task.isCancelled { throw CancellationError() }

            // Verify volume reachability if an enumeration fails on a volatile mount
            if listings.contains(where: \.enumerationFailed), location.isVolatile {
                let reachable = await Task.detached(priority: .utility) {
                    (try? location.url.checkResourceIsReachable()) ?? true
                }.value
                if !reachable { throw CocoaError(.fileNoSuchFile) }
            }

            for listing in listings {
                for subdirectory in listing.subdirectories where seenPaths.insert(subdirectory).inserted {
                    pending.append(subdirectory)
                }
                for item in listing.items where seenPaths.insert(item.path).inserted {
                    collected.append(item)
                }
            }

            onProgress?(collected.count)
        }

        return collected
    }

    // MARK: - Metadata Snapshot

    /// Walks directory metadata only (no file reads) to build a snapshot for
    /// cheap change detection. Enumerated with the same parallelism as `scan`.
    func snapshot(rootPath: String) async throws -> [CachedDirectorySnapshot] {
        var snapshots: [CachedDirectorySnapshot] = []
        var pending = [rootPath]
        var seen: Set<String> = [rootPath]

        while !pending.isEmpty {
            if Task.isCancelled { throw CancellationError() }

            let batchCount = min(Self.enumerationConcurrency, pending.count)
            let batch = Array(pending.suffix(batchCount))
            pending.removeLast(batchCount)

            let listings = await withTaskGroup(of: SnapshotListing.self) { group in
                for path in batch {
                    group.addTask { Self.snapshotDirectory(path) }
                }
                var results: [SnapshotListing] = []
                results.reserveCapacity(batchCount)
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for listing in listings {
                if let snapshot = listing.snapshot {
                    snapshots.append(snapshot)
                }
                for subdirectory in listing.subdirectories where seen.insert(subdirectory).inserted {
                    pending.append(subdirectory)
                }
            }
        }

        return snapshots
    }

    struct SnapshotDiff: Sendable {
        var modifiedOrAdded: [String]
        var removed: [String]
        var hasChanges: Bool { !modifiedOrAdded.isEmpty || !removed.isEmpty }
    }

    /// Compares two snapshots and returns structured diff of added/modified vs removed directories.
    func diffSnapshots(current: [CachedDirectorySnapshot], cached: [CachedDirectorySnapshot]) -> SnapshotDiff {
        let cachedByPath = Dictionary(uniqueKeysWithValues: cached.map { ($0.path, $0) })
        let currentPaths = Set(current.map(\.path))
        var modifiedOrAdded: [String] = []
        var removed: [String] = []

        for currentSnapshot in current {
            guard let old = cachedByPath[currentSnapshot.path] else {
                modifiedOrAdded.append(currentSnapshot.path)
                continue
            }

            if currentSnapshot.modificationDate != old.modificationDate
                || currentSnapshot.entryCount != old.entryCount {
                modifiedOrAdded.append(currentSnapshot.path)
            }
        }

        // Detect removed directories
        for oldSnapshot in cached where !currentPaths.contains(oldSnapshot.path) {
            removed.append(oldSnapshot.path)
        }

        return SnapshotDiff(modifiedOrAdded: modifiedOrAdded, removed: removed)
    }

    /// Compares two snapshots and returns paths of modified, added, or removed directories.
    func changedDirectories(current: [CachedDirectorySnapshot], cached: [CachedDirectorySnapshot]) -> [String] {
        let diff = diffSnapshots(current: current, cached: cached)
        return diff.modifiedOrAdded + diff.removed
    }

    // MARK: - Directory Workers

    /// Determines if a directory should be skipped during scanning (caches, thumbnails, trash, non-photo packages).
    nonisolated static func shouldSkipDirectory(name: String, path: String, isPackage: Bool) -> Bool {
        let lowerName = name.lowercased()
        if excludedDirectoryNames.contains(lowerName) { return true }
        if lowerName.hasSuffix(".lrdata") { return true }

        let ext = (name as NSString).pathExtension.lowercased()
        let isPhotoLibrary = photoLibraryExtensions.contains(ext) || lowerName.hasSuffix(".photoslibrary")

        // Skip non-photo packages (e.g. .app, .framework, .plugin, .bundle)
        if isPackage && !isPhotoLibrary && !lowerName.contains("photo booth library") {
            return true
        }

        // Photos Library internal structure filtering: only allow originals and masters branches
        for libExt in photoLibraryExtensions {
            let marker = ".\(libExt)/"
            if let range = path.range(of: marker, options: .caseInsensitive) {
                let subpath = String(path[range.upperBound...])
                let components = subpath.split(separator: "/", omittingEmptySubsequences: true).map { $0.lowercased() }
                guard let first = components.first else { break }

                // Disallow internal thumbnail, render, database, and cache folders
                if first == "resources" || first == "internal" || first == "database"
                    || first == "private" || first == "thumbnails" || first == "renders"
                    || first == "masks" || first == "derivatives" {
                    return true
                }

                // Scopes branch (shared iCloud photo libraries)
                if first == "scopes" {
                    // Only traverse into originals branches inside scopes; skip resources/derivatives/data
                    if components.contains("resources") || components.contains("data") || components.contains("derivatives") {
                        return true
                    }
                } else if first != "originals" && first != "masters" {
                    // Skip any other internal folders not part of originals/masters
                    return true
                }
                break
            }
        }

        // Photo Booth Library internal thumbnails
        if path.localizedCaseInsensitiveContains("Photo Booth Library") {
            if lowerName == "thumbnails" { return true }
        }

        return false
    }

    private nonisolated static func enumerate(directoryPath: String) -> EnumerationResult {
        if Task.isCancelled {
            return EnumerationResult(subdirectories: [], items: [], enumerationFailed: false)
        }

        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(scanKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return EnumerationResult(subdirectories: [], items: [], enumerationFailed: true)
        }

        var subdirectories: [String] = []
        var items: [ImageItem] = []

        for child in contents {
            if Task.isCancelled { break }

            guard let values = try? child.resourceValues(forKeys: scanKeys) else { continue }
            if values.isSymbolicLink == true { continue }

            let childPath = child.standardizedFileURL.path
            if values.isDirectory == true {
                if shouldSkipDirectory(name: child.lastPathComponent, path: childPath, isPackage: values.isPackage == true) {
                    continue
                }
                subdirectories.append(childPath)
                continue
            }

            guard values.isRegularFile == true, let item = makeItem(url: child, values: values) else { continue }
            items.append(item)
        }

        return EnumerationResult(subdirectories: subdirectories, items: items, enumerationFailed: false)
    }

    private struct SnapshotListing: Sendable {
        var snapshot: CachedDirectorySnapshot?
        var subdirectories: [String]
    }

    private nonisolated static func snapshotDirectory(_ directoryPath: String) -> SnapshotListing {
        if Task.isCancelled {
            return SnapshotListing(snapshot: nil, subdirectories: [])
        }

        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let directoryValues = try? directoryURL.resourceValues(forKeys: [.contentModificationDateKey])

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return SnapshotListing(snapshot: nil, subdirectories: [])
        }

        var subdirectories: [String] = []
        for child in contents {
            if Task.isCancelled { break }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                let childPath = child.standardizedFileURL.path
                if shouldSkipDirectory(name: child.lastPathComponent, path: childPath, isPackage: values?.isPackage == true) {
                    continue
                }
                subdirectories.append(childPath)
            }
        }

        let snapshot = CachedDirectorySnapshot(
            path: directoryPath,
            modificationDate: directoryValues?.contentModificationDate,
            entryCount: contents.count
        )
        return SnapshotListing(snapshot: snapshot, subdirectories: subdirectories)
    }

    nonisolated static func makeItem(url: URL, values: URLResourceValues) -> ImageItem? {
        let filePath = url.standardizedFileURL.path

        // Exclude internal derivatives and non-original files in Photos libraries
        for libExt in photoLibraryExtensions {
            let marker = ".\(libExt)/"
            if let range = filePath.range(of: marker, options: .caseInsensitive) {
                let subpath = String(filePath[range.upperBound...]).lowercased()
                let isOriginal = subpath.contains("/originals/") || subpath.contains("/masters/")
                    || subpath.hasPrefix("originals/") || subpath.hasPrefix("masters/")
                guard isOriginal else { return nil }
                break
            }
        }

        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let pathExtension = url.pathExtension.lowercased()

        let isDeclaredImage = type?.conforms(to: .image) == true
        let isKnownCustomImage = customImageExtensions.contains(pathExtension)
        guard isDeclaredImage || isKnownCustomImage else { return nil }

        let swiftRenderableExtensions: Set<String> = [
            "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "gif",
            "webp", "bmp", "ico", "svg", "avif", "jxl"
        ]
        let isSwiftRenderable = swiftRenderableExtensions.contains(pathExtension)
        let isMovieLike = type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true

        let stableID = ImageItem.stableID(for: filePath)
        return ImageItem(
            id: stableID,
            path: filePath,
            name: url.lastPathComponent,
            parentPath: url.deletingLastPathComponent().standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate,
            typeIdentifier: type?.identifier ?? "public.data",
            isSwiftRenderable: isSwiftRenderable,
            isMovieLike: isMovieLike
        )
    }
}

// MARK: - Decode Limiter

/// Priority-aware concurrency gate for image decoding.
/// Lower priority values execute first; equal priorities are processed in FIFO order.
private actor DecodeLimiter {
    private let maxConcurrent: Int
    private var running = 0
    private var nextSequence: UInt64 = 0
    private var waiters: [Waiter] = []

    private struct Waiter {
        let priority: Int
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func withPermit<T: Sendable>(priority: Int, operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(priority: priority)
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire(priority: Int) async {
        if running < maxConcurrent {
            running += 1
            return
        }
        let sequence = nextSequence
        nextSequence &+= 1
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(priority: priority, sequence: sequence, continuation: continuation))
        }
    }

    private func release() {
        running -= 1
        let bestIndex = waiters.indices.max(by: { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority != right.priority { return left.priority > right.priority }
            return left.sequence > right.sequence
        })
        guard let bestIndex else { return }
        let winner = waiters.remove(at: bestIndex)
        running += 1
        winner.continuation.resume()
    }
}

// MARK: - Thumbnail Provider

/// Actor managing asynchronous image decoding with memory-budgeted caching.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private enum Kind {
        case thumbnail
        case fullImage

        /// Lower jumps the queue ahead of lower-priority work.
        var queuePriority: Int {
            switch self {
            case .fullImage: return 0
            case .thumbnail: return 1
            }
        }

        var taskPriority: TaskPriority {
            switch self {
            case .fullImage: return .high
            case .thumbnail: return .userInitiated
            }
        }
    }

    private let thumbnailCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()

    /// A few full-resolution images are kept so navigating back in the viewer
    /// is instant. Byte-cost budgeted since full-res bitmaps are large.
    private let fullImageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 4
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    private let limiter = DecodeLimiter(maxConcurrent: 6)
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let memoryPressureSource: DispatchSourceMemoryPressure

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [thumbnailCache, fullImageCache] in
            thumbnailCache.removeAllObjects()
            fullImageCache.removeAllObjects()
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Thumbnail for grid cells (480px long edge, embedded preview when available).
    func thumbnail(path: String) async -> NSImage? {
        await decode(path: path, kind: .thumbnail)
    }

    /// Full-resolution image for the viewer (capped at 4096px long edge,
    /// EXIF orientation applied, HDR gain maps preserved).
    func fullImage(path: String) async -> NSImage? {
        await decode(path: path, kind: .fullImage)
    }

    /// Drops all decoded images. Called automatically on memory pressure.
    func purgeCaches() {
        thumbnailCache.removeAllObjects()
        fullImageCache.removeAllObjects()
    }

    private func cachedImage(for url: URL, kind: Kind) -> NSImage? {
        let store = kind == .thumbnail ? thumbnailCache : fullImageCache
        return store.object(forKey: url as NSURL)
    }

    private func storeImage(_ image: NSImage, for url: URL, cost: Int, kind: Kind) {
        let store = kind == .thumbnail ? thumbnailCache : fullImageCache
        store.setObject(image, forKey: url as NSURL, cost: cost)
    }

    private func decode(path: String, kind: Kind) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        if let cached = cachedImage(for: url, kind: kind) {
            return cached
        }

        let key = kind == .thumbnail ? "t\u{0}\(path)" : "f\u{0}\(path)"
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<NSImage?, Never>(priority: kind.taskPriority) { [weak self, limiter] in
            guard let self else { return nil }
            return await limiter.withPermit(priority: kind.queuePriority) {
                if let cached = await self.cachedImage(for: url, kind: kind) {
                    return cached
                }
                guard let result = ThumbnailProvider.render(url: url, kind: kind) else {
                    return nil
                }
                await self.storeImage(result.image, for: url, cost: result.cost, kind: kind)
                return result.image
            }
        }

        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    private struct RenderResult {
        let image: NSImage
        let cost: Int
    }

    private nonisolated static func render(url: URL, kind: Kind) -> RenderResult? {
        if url.pathExtension.lowercased() == "svg" {
            // Runs on the structured task pool, never on the main thread.
            guard let image = NSImage(contentsOf: url) else { return nil }
            return RenderResult(image: image, cost: 1024 * 1024)
        }

        let shouldCache = kind == .fullImage
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: shouldCache
        ] as CFDictionary) else { return nil }

        let options: [CFString: Any]
        if kind == .fullImage {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let originalWidth = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let originalHeight = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            // Cap at 4096px to avoid excessive memory usage while preserving Retina quality.
            let maxLoadDimension = min(max(originalWidth, originalHeight, 1), 4096)

            options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLoadDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
        } else {
            // Use embedded thumbnail if present for faster grid loading.
            options = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
            ]
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let cost = cgImage.width * cgImage.height * 4

        if kind == .fullImage {
            let maxDisplaySize: CGFloat = 1920
            let pixelWidth = CGFloat(cgImage.width)
            let pixelHeight = CGFloat(cgImage.height)
            let displayScale = min(maxDisplaySize / max(pixelWidth, pixelHeight), 1.0)
            let image = NSImage(cgImage: cgImage, size: NSSize(
                width: pixelWidth * displayScale,
                height: pixelHeight * displayScale
            ))
            return RenderResult(image: image, cost: cost)
        }

        return RenderResult(image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), cost: cost)
    }
}
