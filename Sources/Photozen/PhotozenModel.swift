import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PhotozenModel: ObservableObject {
    @Published var locations: [FolderLocation] = []
    @Published var selectedRootID: UUID?
    @Published var sidebarSelection: SidebarSelection?
    @Published var images: [ImageItem] = []
    @Published var isScanning = false
    @Published var isRefreshing = false
    @Published var indexedCount: Int = 0
    @Published var scanError: String?
    @Published var filter = ImageFilter()
    @Published var presentFolderPicker = false
    @Published var isInfoOpen = false
    @Published var searchFocusTrigger = 0
    @Published var showKeyboardShortcuts = false
    @Published private(set) var filteredImages: [ImageItem] = []
    @Published private(set) var dateGroups: [DateGroup] = []
    @Published private(set) var lastUpdated: Date?

    func focusSearch() {
        searchFocusTrigger &+= 1
    }

    private let scanner = ImageScanner()
    private var scanTask: Task<Void, Never>?
    private var scanningLocationID: UUID?
    private var scanCounter: UInt64 = 0
    private var rebuildCounter: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private let monitor = DirectoryMonitor()
    private var cachedIndexes: [String: CachedIndex] = [:]

    var selectedRoot: FolderLocation? {
        locations.first { $0.id == selectedRootID }
    }

    var currentTitle: String {
        if let selection = sidebarSelection {
            switch selection {
            case .location(let id):
                return locations.first(where: { $0.id == id })?.name ?? "Photos"
            case .subfolder(_, let path):
                return URL(fileURLWithPath: path).lastPathComponent
            case .image(_, let item):
                return item.name
            }
        }
        return selectedRoot?.name ?? "Photozen"
    }

    var hasAnyImages: Bool {
        !images.isEmpty
    }

    /// Set by ContentView to the URL of the currently viewed or selected image.
    @Published var printableImageURL: URL? = nil

    var canPrint: Bool {
        printableImageURL != nil
    }

    func printCurrentImage() {
        guard let url = printableImageURL,
              let image = NSImage(contentsOf: url) else { return }

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true

        let operation = NSPrintOperation(view: imageView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    init() {
        observeUnmounts()
        setupMonitor()
        loadPersistedLocations()
        observeFilterChanges()
        // Refresh volume availability asynchronously after launch
        Task { await handleVolumeChange() }
        if selectedRootID == nil, let first = locations.first {
            selectedRootID = first.id
            sidebarSelection = .location(first.id)
            Task { await scan(locationID: first.id) }
        }
    }

    private func setupMonitor() {
        monitor.onChange = { [weak self] changedRootPath in
            Task { await self?.handleLiveChange(forPath: changedRootPath) }
        }
    }

    // MARK: - Derived Data

    private func rebuildDerivedData() {
        rebuildCounter &+= 1
        let generation = rebuildCounter
        let source = images
        let activeFilter = filter

        // Perform filtering and grouping off the main thread
        Task.detached(priority: .userInitiated) { [weak self] in
            let matching = source.filter { activeFilter.matches($0) }
            let result = DateGrouper.groupAndSort(matching, sortByDate: activeFilter.sortByDate)
            await self?.applyDerivedData(result, generation: generation)
        }
    }

    private func applyDerivedData(_ result: (sorted: [ImageItem], groups: [DateGroup]), generation: UInt64) {
        guard rebuildCounter == generation else { return }
        filteredImages = result.sorted
        dateGroups = result.groups
    }

    private func observeFilterChanges() {
        $filter
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildDerivedData()
            }
            .store(in: &cancellables)
    }

    private func setImages(_ newImages: [ImageItem]) {
        images = newImages
        rebuildDerivedData()
    }

    // MARK: - Folder Management

    func photoCount(for locationID: UUID) -> Int? {
        if selectedRootID == locationID {
            return images.count
        }
        if let location = locations.first(where: { $0.id == locationID }),
           let cached = cachedIndexes[location.path] {
            return cached.items.count
        }
        return nil
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .package]
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose folders, Photos Libraries, external drives, or network shares to index."

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var addedAny = false
        for url in panel.urls {
            guard let location = try? LocationDiscovery.makeLocation(for: url) else { continue }
            guard !locations.contains(where: { $0.path == location.path }) else { continue }
            locations.append(location)
            addedAny = true
        }

        guard addedAny, let newest = locations.last else { return }
        persistLocations()
        setSidebarSelection(.location(newest.id))
    }

    func setSidebarSelection(_ selection: SidebarSelection?) {
        self.sidebarSelection = selection
        guard let selection else {
            selectedRootID = nil
            filter.subfolderPath = nil
            rebuildDerivedData()
            return
        }
        switch selection {
        case .location(let id):
            let pathChanged = filter.subfolderPath != nil
            filter.subfolderPath = nil
            if selectedRootID != id {
                selectedRootID = id
                Task { await scan(locationID: id) }
            } else if pathChanged {
                rebuildDerivedData()
            }
        case .subfolder(let id, let path):
            let pathChanged = filter.subfolderPath != path
            filter.subfolderPath = path
            if selectedRootID != id {
                selectedRootID = id
                Task { await scan(locationID: id) }
            } else if pathChanged {
                rebuildDerivedData()
            }
        case .image(let id, let item):
            let pathChanged = filter.subfolderPath != item.parentPath
            filter.subfolderPath = item.parentPath
            if selectedRootID != id {
                selectedRootID = id
                Task { await scan(locationID: id) }
            } else if pathChanged {
                rebuildDerivedData()
            }
        }
    }

    func selectRoot(_ id: UUID) {
        setSidebarSelection(.location(id))
    }

    func disconnectSelectedRoot() async {
        guard let root = selectedRoot else { return }
        await disconnect(locationID: root.id)
    }

    func disconnect(locationID: UUID) async {
        guard let location = locations.first(where: { $0.id == locationID }) else { return }

        // Cancel any in-flight scan of this location.
        if scanningLocationID == locationID {
            scanTask?.cancel()
            scanTask = nil
            scanningLocationID = nil
            isScanning = false
        }

        monitor.stopMonitoring(path: location.path)
        cachedIndexes.removeValue(forKey: location.path)
        // Free the on-disk index too — nothing references it anymore.
        await IndexCache.shared.remove(rootPath: location.path)
        // Free decoded image thumbnails and metadata cache to save memory resources.
        await ThumbnailProvider.shared.purgeCaches()
        await ImageMetadataService.shared.clearCache()

        locations.removeAll { $0.id == locationID }
        if selectedRootID == locationID {
            selectedRootID = nil
            sidebarSelection = nil
            filter.subfolderPath = nil
            setImages([])
            scanError = nil
        }
        persistLocations()
    }

    func rescanSelected() {
        refreshSelected()
    }

    func forceRecreateCacheSelected() {
        guard let id = selectedRootID, let location = selectedRoot else { return }
        if scanningLocationID == id {
            scanTask?.cancel()
            scanTask = nil
            scanningLocationID = nil
        }

        scanCounter &+= 1
        let generation = scanCounter
        scanningLocationID = id

        scanTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            self.cachedIndexes.removeValue(forKey: location.path)
            await IndexCache.shared.remove(rootPath: location.path)
            await self.fullScan(location: location, generation: generation)
            if self.scanningLocationID == id, self.scanCounter == generation {
                self.scanningLocationID = nil
                self.scanTask = nil
            }
        }
    }

    func refreshSelected() {
        guard let id = selectedRootID, let location = selectedRoot else { return }
        if scanningLocationID == id {
            scanTask?.cancel()
            scanTask = nil
            scanningLocationID = nil
        }

        scanCounter &+= 1
        let generation = scanCounter
        scanningLocationID = id

        scanTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefresh(location: location, generation: generation)
            if self.scanningLocationID == id, self.scanCounter == generation {
                self.scanningLocationID = nil
                self.scanTask = nil
            }
        }
    }

    private func performRefresh(location: FolderLocation, generation: UInt64) async {
        guard scanCounter == generation, !Task.isCancelled else { return }

        // Compare disk to cache incrementally without resetting images
        let cached: CachedIndex?
        if let inMemory = cachedIndexes[location.path] {
            cached = inMemory
        } else {
            cached = await IndexCache.shared.load(rootPath: location.path)
        }
        guard !Task.isCancelled else { return }

        if let cached, !cached.items.isEmpty {
            cachedIndexes[location.path] = cached
            await verifyAndRefresh(location: location, cachedIndex: cached, generation: generation)
        } else {
            await fullScan(location: location, generation: generation)
        }
    }

    // MARK: - Scanning

    func scan(locationID: UUID) async {
        guard let location = locations.first(where: { $0.id == locationID }) else { return }
        if scanningLocationID == locationID, scanTask != nil { return }

        scanningLocationID = locationID
        scanCounter &+= 1
        let generation = scanCounter

        scanTask?.cancel()
        scanTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performScan(location: location, generation: generation)
            if self.scanningLocationID == locationID, self.scanCounter == generation {
                self.scanningLocationID = nil
                self.scanTask = nil
            }
        }
    }

    private func performScan(location: FolderLocation, generation: UInt64) async {
        // 1. Load cached index if available
        let cached = await IndexCache.shared.load(rootPath: location.path)
        guard !Task.isCancelled else { return }

        if let cached, !cached.items.isEmpty {
            cachedIndexes[location.path] = cached

            if selectedRootID == location.id {
                setImages(cached.items)
                indexedCount = cached.items.count
                isScanning = false
                scanError = nil
                lastUpdated = cached.lastScanned
            }

            // 2. Check for filesystem changes in background
            await verifyAndRefresh(location: location, cachedIndex: cached, generation: generation)
        } else {
            await fullScan(location: location, generation: generation)
        }

        // 3. Monitor for live changes
        if scanCounter == generation, !Task.isCancelled {
            monitor.startMonitoring(path: location.path)
        }
    }

    private func fullScan(location: FolderLocation, generation: UInt64) async {
        guard scanCounter == generation, !Task.isCancelled else { return }

        let affectsUI = selectedRootID == location.id
        if affectsUI {
            isScanning = true
            scanError = nil
            indexedCount = 0
            setImages([])
        }

        do {
            let results = try await scanner.scan(location: location) { [weak self] count in
                Task { @MainActor [weak self] in
                    guard let self, self.scanCounter == generation, self.selectedRootID == location.id else { return }
                    self.indexedCount = count
                }
            }
            guard !Task.isCancelled else { throw CancellationError() }

            if affectsUI, selectedRootID == location.id {
                setImages(results)
                indexedCount = results.count
            }
            updateLocationStatus(id: location.id, status: .available)

            // Cache scan results and directory snapshots
            let snapshots = try await scanner.snapshot(rootPath: location.path)
            guard !Task.isCancelled else { throw CancellationError() }

            let index = CachedIndex(
                rootPath: location.path,
                lastScanned: Date(),
                items: results,
                directorySnapshots: snapshots
            )
            cachedIndexes[location.path] = index
            await IndexCache.shared.save(index)
        } catch is CancellationError {
            // Cancelled by superseded scan
        } catch {
            if affectsUI, selectedRootID == location.id {
                let reachable = await Self.checkReachable(location.url)
                if location.isVolatile && !reachable {
                    scanError = "The volume or share “\(location.name)” is no longer available."
                    updateLocationStatus(id: location.id, status: .missing)
                } else {
                    scanError = error.localizedDescription
                }
            }
        }

        if scanCounter == generation, affectsUI {
            isScanning = false
            lastUpdated = Date()
        }
    }

    private func verifyAndRefresh(location: FolderLocation, cachedIndex: CachedIndex, generation: UInt64) async {
        let affectsUI = selectedRootID == location.id
        if affectsUI {
            isRefreshing = true
        }
        defer {
            if affectsUI {
                isRefreshing = false
                lastUpdated = Date()
            }
        }

        // Take directory snapshots to detect changed subtrees
        let currentSnapshots: [CachedDirectorySnapshot]
        do {
            currentSnapshots = try await scanner.snapshot(rootPath: location.path)
        } catch is CancellationError {
            return
        } catch {
            if scanCounter == generation, !Task.isCancelled {
                await fullScan(location: location, generation: generation)
            }
            return
        }
        guard !Task.isCancelled else { return }

        let diff = await scanner.diffSnapshots(current: currentSnapshots, cached: cachedIndex.directorySnapshots)
        let hasInvalidCachedItems = cachedIndex.items.contains(where: { Self.isInvalidCachedItem($0) })
        guard !Task.isCancelled, (diff.hasChanges || hasInvalidCachedItems) else { return }

        await incrementalScan(
            location: location,
            cachedIndex: cachedIndex,
            diff: diff,
            freshSnapshots: currentSnapshots
        )
    }

    private func incrementalScan(
        location: FolderLocation,
        cachedIndex: CachedIndex,
        diff: ImageScanner.SnapshotDiff,
        freshSnapshots: [CachedDirectorySnapshot]
    ) async {
        // Rescan modified or added subtrees concurrently (never removed paths)
        var rescanned: [ImageItem] = []
        if !diff.modifiedOrAdded.isEmpty {
            await withTaskGroup(of: [ImageItem].self) { group in
                for changedPath in diff.modifiedOrAdded {
                    group.addTask { [scanner] in
                        let subLocation = FolderLocation(
                            id: location.id,
                            path: changedPath,
                            name: location.name,
                            kind: location.kind,
                            isVolatile: location.isVolatile,
                            status: .available,
                            lastSeen: Date()
                        )
                        return (try? await scanner.scan(location: subLocation)) ?? []
                    }
                }
                for await items in group {
                    rescanned.append(contentsOf: items)
                }
            }
        }
        guard !Task.isCancelled else { return }

        // Merge changes into cached item list, pruning invalid and removed items
        let merged = await Self.mergeIncremental(
            cachedItems: cachedIndex.items,
            modifiedOrAddedPaths: diff.modifiedOrAdded,
            removedPaths: diff.removed,
            rescannedItems: rescanned
        )
        guard !Task.isCancelled else { return }

        if selectedRootID == location.id {
            setImages(merged)
        }

        let updated = CachedIndex(
            rootPath: location.path,
            lastScanned: Date(),
            items: merged,
            directorySnapshots: freshSnapshots
        )
        cachedIndexes[location.path] = updated
        await IndexCache.shared.save(updated)
    }

    /// Identifies whether an item violates current exclusion rules (e.g. photos library derivatives or cache paths).
    nonisolated static func isInvalidCachedItem(_ item: ImageItem) -> Bool {
        let path = item.path

        for libExt in ImageScanner.photoLibraryExtensions {
            let marker = ".\(libExt)/"
            if let range = path.range(of: marker, options: .caseInsensitive) {
                let subpath = String(path[range.upperBound...]).lowercased()
                let isOriginal = subpath.contains("/originals/") || subpath.contains("/masters/")
                    || subpath.hasPrefix("originals/") || subpath.hasPrefix("masters/")
                if !isOriginal { return true }
                break
            }
        }

        let lower = path.lowercased()
        if lower.contains("/@eadir/") || lower.contains("/.thumbnails/") || lower.contains("/thumbnails/")
            || lower.contains(".lrdata/") || lower.contains("/.trash/") {
            return true
        }

        return false
    }

    /// Merges rescanned items into existing cached items, removing pruned paths.
    nonisolated private static func mergeIncremental(
        cachedItems: [ImageItem],
        modifiedOrAddedPaths: [String],
        removedPaths: [String],
        rescannedItems: [ImageItem]
    ) async -> [ImageItem] {
        await Task.yield()
        let modifiedSet = Set(modifiedOrAddedPaths)
        let removedSet = Set(removedPaths)
        let modifiedPrefixes = modifiedOrAddedPaths.map { $0 + "/" }
        let removedPrefixes = removedPaths.map { $0 + "/" }

        var merged: [ImageItem] = []
        merged.reserveCapacity(cachedItems.count + rescannedItems.count)

        outer: for item in cachedItems {
            // Prune invalid or legacy cached items
            if isInvalidCachedItem(item) { continue }

            // Prune modified and removed paths
            if modifiedSet.contains(item.parentPath) || removedSet.contains(item.parentPath) { continue }
            for prefix in modifiedPrefixes where item.path.hasPrefix(prefix) { continue outer }
            for prefix in removedPrefixes where item.path.hasPrefix(prefix) { continue outer }
            merged.append(item)
        }

        var seen = Set(merged.map(\.path))
        for item in rescannedItems where seen.insert(item.path).inserted {
            if !isInvalidCachedItem(item) {
                merged.append(item)
            }
        }
        return merged
    }

    private func handleLiveChange(forPath rootPath: String) async {
        guard let location = locations.first(where: { $0.path == rootPath }) else { return }
        guard let cached = cachedIndexes[rootPath] else {
            await scan(locationID: location.id)
            return
        }

        await verifyAndRefresh(location: location, cachedIndex: cached, generation: scanCounter)
    }

    private func updateLocationStatus(id: UUID, status: ItemStatus) {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        locations[index].status = status
        locations[index].lastSeen = Date()
    }

    // MARK: - Unmount Monitoring

    private func observeUnmounts() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.handleVolumeChange() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.handleVolumeChange() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willUnmountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.handleVolumeChange() }
            }
            .store(in: &cancellables)
    }

    private func handleVolumeChange() async {
        let snapshot = locations
        guard !snapshot.isEmpty else { return }

        // Check reachability for all locations concurrently
        let statuses: [UUID: Bool] = await withTaskGroup(of: (UUID, Bool).self) { group in
            for location in snapshot {
                group.addTask {
                    (location.id, await PhotozenModel.checkReachable(location.url))
                }
            }
            var results: [UUID: Bool] = [:]
            for await (id, reachable) in group {
                results[id] = reachable
            }
            return results
        }

        for index in locations.indices {
            let location = locations[index]
            guard let reachable = statuses[location.id] else { continue }
            let newStatus: ItemStatus = reachable ? .available : .missing
            guard locations[index].status != newStatus else { continue }

            locations[index].status = newStatus
            locations[index].lastSeen = Date()

            if !reachable {
                if selectedRootID == location.id {
                    scanError = "The volume or share “\(location.name)” is no longer available."
                    setImages([])
                }
            } else if selectedRootID == location.id, images.isEmpty {
                await scan(locationID: location.id)
            }
        }
        persistLocations()
    }

    /// Asynchronously verifies URL reachability off the main thread.
    nonisolated private static func checkReachable(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            (try? url.checkResourceIsReachable()) ?? false
        }.value
    }

    // MARK: - Persistence

    private func persistLocations() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(locations) {
            UserDefaults.standard.set(data, forKey: "PhotozenLocations")
        }
    }

    private func loadPersistedLocations() {
        guard let data = UserDefaults.standard.data(forKey: "PhotozenLocations") else { return }
        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([FolderLocation].self, from: data) {
            locations = loaded
        }
    }

    // MARK: - Item Actions

    func openItem(_ item: ImageItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(_ item: ImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
