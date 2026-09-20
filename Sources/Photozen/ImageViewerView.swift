import AppKit
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

enum ViewerNavigation {
    case next
    case previous
}

enum GestureAxis {
    case uncommitted
    case horizontal
    case vertical
}

// MARK: - Image Viewer Controller

@MainActor
final class ImageViewerController: NSObject, ObservableObject {
    @Published var items: [ImageItem]
    @Published var currentItem: ImageItem
    @Published var fullImage: NSImage?
    @Published var isFullResLoaded: Bool = false
    @Published var prevThumbnail: NSImage?
    @Published var nextThumbnail: NSImage?

    // Horizontal slide
    @Published var slideOffset: CGFloat = 0
    @Published var isAnimatingSlide: Bool = false

    // Vertical gestures: dismiss & info panel
    @Published var verticalDismissOffset: CGFloat = 0
    @Published var isFlyingToGrid: Bool = false
    @Published var backdropOpacity: Double = 1.0
    @Published var isInfoPanelOpen: Bool = false
    @Published var infoPanelPullOffset: CGFloat = 0
    @Published var photoMetadata: PhotoMetadata? = nil
    @Published var isLoadingMetadata: Bool = false

    // Zoom & Pan
    @Published var zoomScale: CGFloat = 1.0
    @Published var baseScale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var dragTranslation: CGSize = .zero

    var containerSize: CGSize = .zero
    var fittedImageSize: CGSize = .zero
    var mouseLocation: CGPoint?
    var targetGridRect: CGRect?

    var isPinching: Bool = false
    private var pinchDebounceTask: Task<Void, Never>? = nil

    var onClose: (() -> Void)?
    var onSelectionChanged: ((ImageItem) -> Void)?

    let minZoom: CGFloat = 1.0
    let maxZoom: CGFloat = 10.0
    let slideSpacing: CGFloat = 30.0
    let infoPanelHeight: CGFloat = 420.0

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var recentDeltaX: CGFloat = 0
    private var recentDeltaY: CGFloat = 0
    private var isTrackingGesture: Bool = false
    var gestureAxis: GestureAxis = .uncommitted

    private var decodeTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    init(
        items: [ImageItem],
        initialItem: ImageItem,
        targetGridRect: CGRect? = nil,
        onClose: (() -> Void)? = nil,
        onSelectionChanged: ((ImageItem) -> Void)? = nil
    ) {
        self.items = items
        self.currentItem = initialItem
        self.targetGridRect = targetGridRect
        self.onClose = onClose
        self.onSelectionChanged = onSelectionChanged
        super.init()
    }

    var currentIndex: Int {
        items.firstIndex(where: { $0.id == currentItem.id }) ?? 0
    }

    var prevItem: ImageItem? {
        let idx = currentIndex
        guard idx > 0 else { return nil }
        return items[idx - 1]
    }

    var nextItem: ImageItem? {
        let idx = currentIndex
        guard idx + 1 < items.count else { return nil }
        return items[idx + 1]
    }

    // MARK: - Image & Metadata Loading

    func loadActiveImage(preferredInitial: NSImage? = nil) {
        guard !items.isEmpty else { return }
        let path = currentItem.path

        decodeTask?.cancel()
        preloadTask?.cancel()
        isFullResLoaded = false

        if let preferred = preferredInitial {
            self.fullImage = preferred
        }

        // Decode high-res image immediately without waiting for neighbor thumbnails
        decodeTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            if self.fullImage == nil {
                let thumb = await ThumbnailProvider.shared.thumbnail(path: path)
                guard !Task.isCancelled else { return }
                if self.fullImage == nil {
                    self.fullImage = thumb
                }
            }

            let sharp = await ThumbnailProvider.shared.fullImage(path: path)
            guard !Task.isCancelled else { return }

            if let sharp = sharp {
                self.fullImage = sharp
                self.isFullResLoaded = true
            }
        }

        // Concurrently preload adjacent thumbnails in background
        let pPath = prevItem?.path
        let nPath = nextItem?.path
        preloadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            async let pThumb: NSImage? = {
                if let p = pPath { return await ThumbnailProvider.shared.thumbnail(path: p) }
                return nil
            }()
            async let nThumb: NSImage? = {
                if let n = nPath { return await ThumbnailProvider.shared.thumbnail(path: n) }
                return nil
            }()

            let (prev, next) = await (pThumb, nThumb)
            guard !Task.isCancelled else { return }
            self.prevThumbnail = prev
            self.nextThumbnail = next
        }

        // Concurrently load metadata & GPS coordinates
        loadMetadata(for: path)
    }

    func loadMetadata(for path: String) {
        metadataTask?.cancel()
        photoMetadata = nil
        isLoadingMetadata = true

        metadataTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let meta = await ImageMetadataService.shared.metadata(for: path)
            guard !Task.isCancelled else { return }
            self.photoMetadata = meta
            self.isLoadingMetadata = false
        }
    }

    func syncExternalItem(_ newItem: ImageItem) {
        guard newItem.id != currentItem.id else { return }
        currentItem = newItem
        slideOffset = 0
        verticalDismissOffset = 0
        backdropOpacity = 1.0
        resetZoom(animated: false)
        loadActiveImage()
    }

    func updateItems(_ newItems: [ImageItem]) {
        self.items = newItems
    }

    // MARK: - Slide Transitions

    func commitSlide(to direction: ViewerNavigation) {
        guard !isAnimatingSlide, !isFlyingToGrid else { return }

        let targetItem: ImageItem? = direction == .next ? nextItem : prevItem
        guard let nextTarget = targetItem else {
            bounceBoundary(direction: direction)
            return
        }

        isAnimatingSlide = true
        let W = containerSize.width > 0 ? containerSize.width : 800
        let targetOffset = direction == .next ? (-W - slideSpacing) : (W + slideSpacing)
        let incomingThumb = direction == .next ? nextThumbnail : prevThumbnail

        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.90)) {
            self.slideOffset = targetOffset
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self = self else { return }
            self.currentItem = nextTarget
            self.slideOffset = 0
            self.isAnimatingSlide = false
            self.resetZoom(animated: false)

            self.onSelectionChanged?(nextTarget)
            self.loadActiveImage(preferredInitial: incomingThumb)
        }
    }

    func snapBackHorizontal() {
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) {
            self.slideOffset = 0
        }
        self.isAnimatingSlide = false
    }

    func bounceBoundary(direction: ViewerNavigation) {
        guard !isAnimatingSlide else { return }
        isAnimatingSlide = true
        let bounceAmount: CGFloat = direction == .next ? -25 : 25
        withAnimation(.easeOut(duration: 0.08)) {
            self.slideOffset = bounceAmount
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.7)) {
                self.slideOffset = 0
            }
            self.isAnimatingSlide = false
        }
    }

    // MARK: - Vertical Gestures (Fly to Grid & Info Panel)

    func commitDismissFlyToGrid() {
        guard !isFlyingToGrid else { return }
        isFlyingToGrid = true

        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82)) {
            self.verticalDismissOffset = 700
            self.backdropOpacity = 0.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self = self else { return }
            self.onClose?()
        }
    }

    func snapBackVertical() {
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) {
            self.verticalDismissOffset = 0
            self.backdropOpacity = 1.0
            if !self.isInfoPanelOpen {
                self.infoPanelPullOffset = 0
            } else {
                self.infoPanelPullOffset = self.infoPanelHeight
            }
        }
        self.gestureAxis = .uncommitted
    }

    func commitOpenInfoPanel() {
        isInfoPanelOpen = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            self.infoPanelPullOffset = self.infoPanelHeight
            self.verticalDismissOffset = 0
            self.backdropOpacity = 1.0
        }
    }

    func commitCloseInfoPanel() {
        isInfoPanelOpen = false
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            self.infoPanelPullOffset = 0
            self.verticalDismissOffset = 0
            self.backdropOpacity = 1.0
        }
    }

    func toggleInfoPanel() {
        if isInfoPanelOpen {
            commitCloseInfoPanel()
        } else {
            commitOpenInfoPanel()
        }
    }

    func handleGestureEnded() {
        guard !isAnimatingSlide, !isFlyingToGrid, zoomScale <= 1.01 else { return }

        if gestureAxis == .horizontal {
            let W = containerSize.width > 0 ? containerSize.width : 800
            let commitThreshold = max(110.0, min(W * 0.18, 180.0))
            let isFlickNext = (slideOffset < -60.0 && recentDeltaX < -20.0)
            let isFlickPrev = (slideOffset > 60.0 && recentDeltaX > 20.0)

            if (slideOffset < -commitThreshold || isFlickNext) && nextItem != nil {
                commitSlide(to: .next)
            } else if (slideOffset > commitThreshold || isFlickPrev) && prevItem != nil {
                commitSlide(to: .previous)
            } else {
                snapBackHorizontal()
            }
        } else if gestureAxis == .vertical {
            if isInfoPanelOpen {
                if accumulatedDeltaY > 70 || recentDeltaY > 15 {
                    commitCloseInfoPanel()
                } else {
                    commitOpenInfoPanel()
                }
            } else {
                if verticalDismissOffset > 0 {
                    let isFlickDismiss = (verticalDismissOffset > 50 && recentDeltaY > 15)
                    if verticalDismissOffset > 90 || isFlickDismiss {
                        commitDismissFlyToGrid()
                    } else {
                        snapBackVertical()
                    }
                } else if infoPanelPullOffset > 0 {
                    let isFlickOpen = (infoPanelPullOffset > 50 && recentDeltaY < -15)
                    if infoPanelPullOffset > 80 || isFlickOpen {
                        commitOpenInfoPanel()
                    } else {
                        snapBackVertical()
                    }
                } else {
                    snapBackVertical()
                }
            }
        }
        gestureAxis = .uncommitted
    }

    // MARK: - Zoom & Pan

    func zoomIn() {
        applyZoom(targetScale: zoomScale + 0.5, anchor: mouseLocation)
    }

    func zoomOut() {
        applyZoom(targetScale: zoomScale - 0.5, anchor: mouseLocation)
    }

    func resetZoom(animated: Bool = true) {
        let update = {
            self.zoomScale = self.minZoom
            self.baseScale = self.minZoom
            self.offset = .zero
            self.dragTranslation = .zero
        }
        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                update()
            }
        } else {
            update()
        }
    }

    func applyZoom(
        targetScale: CGFloat,
        anchor: CGPoint? = nil,
        container: CGSize? = nil,
        fitted: CGSize? = nil,
        animated: Bool = true
    ) {
        let clampedScale = min(max(targetScale, minZoom), maxZoom)
        let current = zoomScale
        guard current > 0 else { return }

        let cont = container ?? (containerSize.width > 0 ? containerSize : CGSize(width: 800, height: 600))
        let fit = fitted ?? (fittedImageSize.width > 0 ? fittedImageSize : cont)
        let containerCenter = CGPoint(x: cont.width / 2, y: cont.height / 2)
        let targetAnchor = anchor ?? mouseLocation ?? containerCenter
        let C = CGPoint(x: targetAnchor.x - containerCenter.x, y: targetAnchor.y - containerCenter.y)
        let ratio = clampedScale / current

        var targetOffsetX = C.x * (1 - ratio) + offset.width * ratio
        var targetOffsetY = C.y * (1 - ratio) + offset.height * ratio

        let maxX = max(0, (fit.width * clampedScale - cont.width) / 2)
        let maxY = max(0, (fit.height * clampedScale - cont.height) / 2)

        targetOffsetX = min(max(targetOffsetX, -maxX), maxX)
        targetOffsetY = min(max(targetOffsetY, -maxY), maxY)

        let update = {
            self.zoomScale = clampedScale
            self.baseScale = clampedScale
            if clampedScale <= self.minZoom {
                self.offset = .zero
                self.dragTranslation = .zero
            } else {
                self.offset = CGSize(width: targetOffsetX, height: targetOffsetY)
            }
        }

        if animated {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                update()
            }
        } else {
            update()
        }
    }

    func panByTrackpad(dx: CGFloat, dy: CGFloat) {
        guard zoomScale > 1.01 else { return }
        let cont = containerSize.width > 0 ? containerSize : CGSize(width: 800, height: 600)
        let fit = fittedImageSize.width > 0 ? fittedImageSize : cont

        let maxX = max(0, (fit.width * zoomScale - cont.width) / 2)
        let maxY = max(0, (fit.height * zoomScale - cont.height) / 2)

        let newX = min(max(offset.width + dx, -maxX), maxX)
        let newY = min(max(offset.height + dy, -maxY), maxY)

        offset = CGSize(width: newX, height: newY)
    }

    func handleDoubleTap(at location: CGPoint) {
        guard slideOffset == 0, verticalDismissOffset == 0 else { return }
        if zoomScale > 1.05 {
            resetZoom(animated: true)
        } else {
            let fit = fittedImageSize.width > 0 ? fittedImageSize : containerSize
            applyZoom(
                targetScale: 2.5,
                anchor: location,
                container: containerSize,
                fitted: fit,
                animated: true
            )
        }
    }

    // MARK: - AppKit Event Monitoring

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .scrollWheel,
            .swipe,
            .magnify,
            .smartMagnify,
            .rightMouseDown,
            .leftMouseDown
        ]) { [weak self] event in
            guard let self = self else { return event }
            return self.handleEvent(event)
        }
    }

    func stopMonitoring() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        recentDeltaX = 0
        recentDeltaY = 0
        isTrackingGesture = false
        isPinching = false
        pinchDebounceTask?.cancel()
        decodeTask?.cancel()
        preloadTask?.cancel()
        metadataTask?.cancel()
    }

    func isLocationInInfoPanel(_ locationInWindow: NSPoint, window: NSWindow) -> Bool {
        guard isInfoPanelOpen, let contentView = window.contentView else { return false }
        let pointInView = contentView.convert(locationInWindow, from: nil)
        let bottomH = infoPanelHeight
        let isInY: Bool
        if contentView.isFlipped {
            isInY = pointInView.y >= (contentView.bounds.height - bottomH) && pointInView.y <= contentView.bounds.height
        } else {
            isInY = pointInView.y >= 0 && pointInView.y <= bottomH
        }
        let isInX = pointInView.x >= 0 && pointInView.x <= contentView.bounds.width
        return isInY && isInX
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window ?? NSApp.keyWindow, window.isKeyWindow else {
            return event
        }

        if let contentView = window.contentView {
            let pointInView = contentView.convert(event.locationInWindow, from: nil)
            guard contentView.bounds.contains(pointInView) else {
                return event
            }
        }

        // When info panel is open and event occurs over the panel, do NOT intercept!
        // Allow the ScrollView / table views to receive all trackpad scrolls and events naturally.
        if isLocationInInfoPanel(event.locationInWindow, window: window) {
            if isTrackingGesture {
                isTrackingGesture = false
                gestureAxis = .uncommitted
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
            }
            return event
        }

        if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            return handleRightMouseDown(event)
        } else if event.type == .magnify {
            return handleMagnifyEvent(event)
        } else if event.type == .smartMagnify {
            return handleSmartMagnifyEvent(event)
        } else if event.type == .swipe {
            return handleSwipeEvent(event)
        } else if event.type == .scrollWheel {
            return handleScrollWheel(event)
        }
        return event
    }

    private func handleRightMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window ?? NSApp.keyWindow, window.isKeyWindow else { return event }
        guard !isLocationInInfoPanel(event.locationInWindow, window: window) else { return event }
        guard let contentView = window.contentView else { return event }
        let pointInView = contentView.convert(event.locationInWindow, from: nil)
        guard contentView.bounds.contains(pointInView) else { return event }

        let menu = buildContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        return nil
    }

    @MainActor
    func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Photo")

        // 1. Copy (⌘C)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopyAction(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyItem)

        // 2. Share…
        let shareItem = NSMenuItem(title: "Share…", action: #selector(contextShareAction(_:)), keyEquivalent: "")
        shareItem.target = self
        shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        menu.addItem(shareItem)

        // 3. Reveal in Finder
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealAction(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(revealItem)

        menu.addItem(.separator())

        // 4. Open With submenu
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWithItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        let openWithSubmenu = NSMenu(title: "Open With")

        let apps = AppPickerMenu.discoverApps(for: currentItem)
        if apps.isEmpty {
            let emptyItem = NSMenuItem(title: "No Applications Found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            openWithSubmenu.addItem(emptyItem)
        } else {
            for app in apps {
                let appItem = NSMenuItem(title: app.name, action: #selector(contextOpenWithAppAction(_:)), keyEquivalent: "")
                appItem.target = self
                appItem.representedObject = app.url
                if let icon = app.icon {
                    appItem.image = icon
                }
                openWithSubmenu.addItem(appItem)
            }
        }

        openWithSubmenu.addItem(.separator())
        let chooseAppItem = NSMenuItem(title: "Choose App…", action: #selector(contextChooseAppAction(_:)), keyEquivalent: "")
        chooseAppItem.target = self
        openWithSubmenu.addItem(chooseAppItem)

        openWithItem.submenu = openWithSubmenu
        menu.addItem(openWithItem)

        menu.addItem(.separator())

        // 5. Get Info / Hide Info (⌘I)
        let infoTitle = isInfoPanelOpen ? "Hide Info" : "Get Info"
        let infoItem = NSMenuItem(title: infoTitle, action: #selector(contextToggleInfoAction(_:)), keyEquivalent: "i")
        infoItem.target = self
        infoItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(infoItem)

        return menu
    }

    @objc private func contextCopyAction(_ sender: Any?) {
        ImageClipboard.copyImage(url: currentItem.url)
    }

    @objc private func contextShareAction(_ sender: Any?) {
        let picker = NSSharingServicePicker(items: [currentItem.url as NSURL])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            let mouseLoc = NSEvent.mouseLocation
            let windowLoc = window.convertPoint(fromScreen: mouseLoc)
            let viewLoc = contentView.convert(windowLoc, from: nil)
            let rect = NSRect(origin: viewLoc, size: CGSize(width: 1, height: 1))
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    @objc private func contextRevealAction(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([currentItem.url])
    }

    @objc private func contextOpenWithAppAction(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([currentItem.url], withApplicationAt: appURL, configuration: configuration)
    }

    @objc private func contextChooseAppAction(_ sender: Any?) {
        AppPickerMenu.chooseApp(for: currentItem.url)
    }

    @objc private func contextToggleInfoAction(_ sender: Any?) {
        if isInfoPanelOpen {
            commitCloseInfoPanel()
        } else {
            commitOpenInfoPanel()
        }
    }

    private func handleMagnifyEvent(_ event: NSEvent) -> NSEvent? {
        guard !isAnimatingSlide, !isFlyingToGrid else { return event }

        let phase = event.phase
        if phase == .began || (!isPinching && abs(event.magnification) > 0.001) {
            isPinching = true
            slideOffset = 0
            verticalDismissOffset = 0
            infoPanelPullOffset = 0
            isTrackingGesture = false
            gestureAxis = .uncommitted
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
        }

        guard isPinching else { return event }

        var anchor: CGPoint? = nil
        if let window = event.window ?? NSApp.keyWindow, let contentView = window.contentView {
            let locInView = contentView.convert(event.locationInWindow, from: nil)
            let y = contentView.isFlipped ? locInView.y : (contentView.bounds.height - locInView.y)
            anchor = CGPoint(x: locInView.x, y: y)
        }

        let scaleMultiplier = 1.0 + event.magnification
        let newTargetScale = zoomScale * scaleMultiplier

        applyZoom(targetScale: newTargetScale, anchor: anchor, animated: false)

        pinchDebounceTask?.cancel()
        if phase == .ended || phase == .cancelled {
            isPinching = false
            baseScale = zoomScale
            if zoomScale <= minZoom {
                resetZoom(animated: true)
            }
        } else {
            pinchDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard let self = self, !Task.isCancelled else { return }
                self.isPinching = false
                self.baseScale = self.zoomScale
                if self.zoomScale <= self.minZoom {
                    self.resetZoom(animated: true)
                }
            }
        }

        return nil
    }

    private func handleSmartMagnifyEvent(_ event: NSEvent) -> NSEvent? {
        guard !isAnimatingSlide, !isFlyingToGrid else { return event }

        var anchor: CGPoint? = nil
        if let window = event.window ?? NSApp.keyWindow, let contentView = window.contentView {
            let locInView = contentView.convert(event.locationInWindow, from: nil)
            let y = contentView.isFlipped ? locInView.y : (contentView.bounds.height - locInView.y)
            anchor = CGPoint(x: locInView.x, y: y)
        }

        if zoomScale > 1.05 {
            resetZoom(animated: true)
        } else {
            applyZoom(targetScale: 2.5, anchor: anchor, animated: true)
        }
        return nil
    }

    private func handleSwipeEvent(_ event: NSEvent) -> NSEvent? {
        guard zoomScale <= 1.01, !isAnimatingSlide, !isFlyingToGrid else { return event }

        if event.deltaX < -0.1 {
            commitSlide(to: .next)
            return nil
        } else if event.deltaX > 0.1 {
            commitSlide(to: .previous)
            return nil
        }
        return event
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard !isPinching else { return nil }

        // Command or Option + Scroll to Zoom
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let dy = event.scrollingDeltaY
            if abs(dy) > 0.1 {
                let zoomFactor: CGFloat = 1.0 + (dy * 0.02)
                applyZoom(targetScale: zoomScale * zoomFactor, anchor: mouseLocation, animated: false)
                return nil
            }
        }

        if zoomScale > 1.01 {
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            recentDeltaX = 0
            recentDeltaY = 0
            isTrackingGesture = false

            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 18.0
            let dx = event.scrollingDeltaX * multiplier
            let dy = event.scrollingDeltaY * multiplier

            if dx != 0 || dy != 0 {
                panByTrackpad(dx: dx, dy: dy)
                return nil
            }
            return nil
        } else {
            return processTrackpadSlide(event)
        }
    }

    private func processTrackpadSlide(_ event: NSEvent) -> NSEvent? {
        guard !isPinching else { return nil }
        guard zoomScale <= 1.01 else { return nil }
        let phase = event.phase
        let momentumPhase = event.momentumPhase
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 18.0
        let dx = event.scrollingDeltaX * multiplier
        let dy = event.scrollingDeltaY * multiplier

        if phase == .began {
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            recentDeltaX = 0
            recentDeltaY = 0
            gestureAxis = .uncommitted
            isTrackingGesture = true
            return nil
        }

        if phase == .changed {
            accumulatedDeltaX += dx
            accumulatedDeltaY += dy
            recentDeltaX = recentDeltaX * 0.3 + dx * 0.7
            recentDeltaY = recentDeltaY * 0.3 + dy * 0.7

            // Disambiguate axis
            if gestureAxis == .uncommitted {
                let dist = hypot(accumulatedDeltaX, accumulatedDeltaY)
                if dist >= 6.0 {
                    if abs(accumulatedDeltaY) > abs(accumulatedDeltaX) * 1.25 {
                        gestureAxis = .vertical
                    } else if abs(accumulatedDeltaX) > abs(accumulatedDeltaY) * 1.25 {
                        gestureAxis = .horizontal
                    }
                }
            }

            guard isTrackingGesture, !isAnimatingSlide, !isFlyingToGrid else { return nil }

            if gestureAxis == .horizontal {
                // Strictly lock vertical offsets: no vertical movement
                verticalDismissOffset = 0
                if !isInfoPanelOpen { infoPanelPullOffset = 0 }

                var newOffset = slideOffset + dx
                let atLeftEdge = currentIndex == 0 && newOffset > 0
                let atRightEdge = currentIndex == items.count - 1 && newOffset < 0
                if atLeftEdge || atRightEdge {
                    newOffset = slideOffset + dx * 0.25
                }
                slideOffset = newOffset
                return nil
            } else if gestureAxis == .vertical {
                // Strictly lock horizontal slide: NO SIDEWAYS JIGGLING WHATSOEVER!
                slideOffset = 0

                let deltaY = dy

                if isInfoPanelOpen {
                    // Open info panel: dragging down (deltaY > 0) collapses it
                    let newPull = max(0, min(infoPanelHeight, infoPanelHeight - (accumulatedDeltaY > 0 ? accumulatedDeltaY : 0)))
                    infoPanelPullOffset = newPull
                } else {
                    if accumulatedDeltaY > 4 || verticalDismissOffset > 0 {
                        // Dragging DOWN: Dismiss
                        verticalDismissOffset = max(0, verticalDismissOffset + deltaY)
                        infoPanelPullOffset = 0
                        backdropOpacity = max(0.15, 1.0 - (Double(verticalDismissOffset) / 220.0) * 0.75)
                    } else if accumulatedDeltaY < -4 || infoPanelPullOffset > 0 {
                        // Dragging UP: Reveal map
                        infoPanelPullOffset = max(0, min(infoPanelHeight, infoPanelPullOffset - deltaY))
                        verticalDismissOffset = 0
                        backdropOpacity = 1.0
                    }
                }
                return nil
            }
            return nil
        }

        if phase == .ended {
            if isTrackingGesture {
                isTrackingGesture = false
                handleGestureEnded()
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
                recentDeltaX = 0
                recentDeltaY = 0
                return nil
            }
            return event
        }

        if phase == .cancelled {
            if isTrackingGesture {
                isTrackingGesture = false
                snapBackVertical()
                snapBackHorizontal()
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
                recentDeltaX = 0
                recentDeltaY = 0
                return nil
            }
            return event
        }

        if momentumPhase == .began || momentumPhase == .changed {
            return nil
        }

        return nil
    }
}

// MARK: - Image Viewer View

struct ImageViewerView: View {
    let items: [ImageItem]
    let selectedItem: ImageItem
    var targetGridRect: CGRect? = nil
    @Binding var isInfoPanelOpen: Bool
    let onClose: () -> Void
    var onSelectionChanged: ((ImageItem) -> Void)? = nil

    @StateObject private var controller: ImageViewerController
    @FocusState private var focused: Bool

    init(
        items: [ImageItem],
        selectedItem: ImageItem,
        targetGridRect: CGRect? = nil,
        isInfoPanelOpen: Binding<Bool> = .constant(false),
        onClose: @escaping () -> Void,
        onSelectionChanged: ((ImageItem) -> Void)? = nil
    ) {
        self.items = items
        self.selectedItem = selectedItem
        self.targetGridRect = targetGridRect
        self._isInfoPanelOpen = isInfoPanelOpen
        self.onClose = onClose
        self.onSelectionChanged = onSelectionChanged
        _controller = StateObject(wrappedValue: ImageViewerController(
            items: items,
            initialItem: selectedItem,
            targetGridRect: targetGridRect,
            onClose: onClose,
            onSelectionChanged: onSelectionChanged
        ))
    }

    var body: some View {
        GeometryReader { geo in
            let bottomPanelHeight = controller.isInfoPanelOpen ? controller.infoPanelHeight : controller.infoPanelPullOffset
            let photoAreaHeight = max(100, geo.size.height - bottomPanelHeight)

            ZStack {
                // Translucent / dark backdrop that fades as image is dragged down
                Color(nsColor: .windowBackgroundColor)
                    .opacity(controller.backdropOpacity)
                    .zIndex(0)
                    .ignoresSafeArea()

                // Main content: Photo Area above and Info/Map Panel below
                VStack(spacing: 0) {
                    // 1. Photo Area
                    photoViewerArea(containerSize: CGSize(width: geo.size.width, height: photoAreaHeight), windowSize: geo.size)
                        .frame(width: geo.size.width, height: photoAreaHeight)

                    // 2. Info & Location Map Panel (emerges from bottom)
                    if bottomPanelHeight > 0 {
                        PhotoInfoMapView(
                            item: controller.currentItem,
                            metadata: controller.photoMetadata,
                            onClose: { controller.commitCloseInfoPanel() }
                        )
                        .frame(width: geo.size.width, height: bottomPanelHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .zIndex(1)

                // Bottom controls overlay (hidden when info panel is active or dragging down)
                if bottomPanelHeight == 0 && controller.verticalDismissOffset < 30 {
                    let isNearBottomRight = (controller.mouseLocation?.x ?? 0) > (geo.size.width - 240) && (controller.mouseLocation?.y ?? 0) > (geo.size.height - 90)

                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            loadingIndicator
                                .allowsHitTesting(true)
                            Spacer()
                            if controller.zoomScale > 1.01 || isNearBottomRight {
                                mapStyleZoomHUD
                                    .allowsHitTesting(true)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }
                        }
                        .padding(16)
                    }
                    .allowsHitTesting(false)
                    .zIndex(2)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .focused($focused)
        .onAppear {
            focused = true
            controller.onClose = onClose
            controller.onSelectionChanged = onSelectionChanged
            controller.targetGridRect = targetGridRect
            controller.startMonitoring()
            controller.loadActiveImage()
            if isInfoPanelOpen && !controller.isInfoPanelOpen {
                controller.commitOpenInfoPanel()
            }
        }
        .onDisappear {
            controller.stopMonitoring()
        }
        .onChange(of: selectedItem.id) { _, _ in
            controller.syncExternalItem(selectedItem)
        }
        .onChange(of: targetGridRect) { _, newRect in
            controller.targetGridRect = newRect
        }
        .onChange(of: items) { _, newItems in
            controller.updateItems(newItems)
        }
        .onChange(of: isInfoPanelOpen) { _, isOpen in
            if isOpen != controller.isInfoPanelOpen {
                if isOpen {
                    controller.commitOpenInfoPanel()
                } else {
                    controller.commitCloseInfoPanel()
                }
            }
        }
        .onChange(of: controller.isInfoPanelOpen) { _, isOpen in
            if isInfoPanelOpen != isOpen {
                isInfoPanelOpen = isOpen
            }
        }
        .background {
            // Hidden keyboard shortcuts
            Group {
                Button("") { controller.onClose?() }
                    .keyboardShortcut(.escape, modifiers: [])

                Button("") { ImageClipboard.copyImage(url: controller.currentItem.url) }
                    .keyboardShortcut("c", modifiers: [.command])

                Button("") { controller.zoomIn() }
                    .keyboardShortcut("=", modifiers: [.command])

                Button("") { controller.zoomIn() }
                    .keyboardShortcut("+", modifiers: [.command])

                Button("") { controller.zoomOut() }
                    .keyboardShortcut("-", modifiers: [.command])

                Button("") { controller.resetZoom(animated: true) }
                    .keyboardShortcut("0", modifiers: [.command])

                Button("") { controller.commitSlide(to: .previous) }
                    .keyboardShortcut(.leftArrow, modifiers: [])

                Button("") { controller.commitSlide(to: .next) }
                    .keyboardShortcut(.rightArrow, modifiers: [])

                // Up arrow: open info panel if closed
                Button("") {
                    if !controller.isInfoPanelOpen {
                        controller.commitOpenInfoPanel()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    // MARK: - Photo Viewer Area

    @ViewBuilder
    private func photoViewerArea(containerSize: CGSize, windowSize: CGSize) -> some View {
        let currentScale = controller.zoomScale

        // Compute geometry for interactive drag-down & flight to grid
        let fitted = controller.fullImage != nil ? Self.aspectFitSize(of: controller.fullImage!, in: containerSize) : controller.fittedImageSize
        let dismissProgress = min(max(controller.verticalDismissOffset / 250.0, 0), 1.0)

        // Calculate target flight offsets if targetGridRect is known
        let targetRect = controller.targetGridRect
        let windowCenterX = windowSize.width / 2
        let windowCenterY = containerSize.height / 2
        let flightDeltaX = targetRect != nil ? (targetRect!.midX - windowCenterX) : 0
        let flightDeltaY = targetRect != nil ? (targetRect!.midY - windowCenterY) : (containerSize.height + 200)
        let flightScale = targetRect != nil && fitted.width > 0 ? (targetRect!.width / fitted.width) : 0.45

        let isFlying = controller.isFlyingToGrid
        let effectiveFlightScale = isFlying ? flightScale : (1.0 - dismissProgress * 0.18)
        let effectiveFlightX = isFlying ? flightDeltaX : (targetRect != nil ? flightDeltaX * dismissProgress * 0.25 : 0)
        let effectiveFlightY = isFlying ? flightDeltaY : controller.verticalDismissOffset
        let effectiveCornerRadius = isFlying ? 4.0 : (4.0 * dismissProgress)

        let effectiveOffset = CGSize(
            width: controller.offset.width + controller.dragTranslation.width + (controller.zoomScale <= 1.01 ? controller.slideOffset : 0) + effectiveFlightX,
            height: controller.offset.height + controller.dragTranslation.height + effectiveFlightY
        )

        ZStack {
            // Previous image preview (slides in from left when slideOffset > 0)
            if let prev = controller.prevThumbnail, controller.slideOffset > 0 {
                let prevFitted = Self.aspectFitSize(of: prev, in: containerSize)
                Image(nsImage: prev)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: prevFitted.width, height: prevFitted.height)
                    .offset(x: -containerSize.width - controller.slideSpacing + controller.slideOffset)
            }

            // Current active image (centered, scalable, pannable, flyable)
            if let image = controller.fullImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: effectiveCornerRadius, style: .continuous))
                    .scaleEffect(currentScale * effectiveFlightScale)
                    .offset(effectiveOffset)
                    .onDrag {
                        NSItemProvider(object: controller.currentItem.url as NSURL)
                    }
            } else {
                ProgressView()
                    .scaleEffect(1.2)
            }

            // Next image preview (slides in from right when slideOffset < 0)
            if let next = controller.nextThumbnail, controller.slideOffset < 0 {
                let nextFitted = Self.aspectFitSize(of: next, in: containerSize)
                Image(nsImage: next)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: nextFitted.width, height: nextFitted.height)
                    .offset(x: containerSize.width + controller.slideSpacing + controller.slideOffset)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                controller.mouseLocation = location
            case .ended:
                controller.mouseLocation = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if controller.zoomScale > 1.01 {
                        controller.dragTranslation = value.translation
                    } else {
                        guard !controller.isPinching, !controller.isAnimatingSlide, !controller.isFlyingToGrid else { return }

                        if controller.gestureAxis == .uncommitted {
                            let dx = value.translation.width
                            let dy = value.translation.height
                            let dist = hypot(dx, dy)
                            if dist >= 6.0 {
                                if abs(dy) > abs(dx) * 1.25 {
                                    controller.gestureAxis = .vertical
                                } else if abs(dx) > abs(dy) * 1.25 {
                                    controller.gestureAxis = .horizontal
                                }
                            }
                        }

                        if controller.gestureAxis == .horizontal {
                            controller.verticalDismissOffset = 0
                            if !controller.isInfoPanelOpen { controller.infoPanelPullOffset = 0 }
                            var dx = value.translation.width
                            let atLeftEdge = controller.currentIndex == 0 && dx > 0
                            let atRightEdge = controller.currentIndex == controller.items.count - 1 && dx < 0
                            if atLeftEdge || atRightEdge {
                                dx *= 0.25
                            }
                            controller.slideOffset = dx
                        } else if controller.gestureAxis == .vertical {
                            controller.slideOffset = 0 // NO SIDEWAYS JIGGLING!
                            let dy = value.translation.height
                            if controller.isInfoPanelOpen {
                                if dy > 0 {
                                    controller.infoPanelPullOffset = max(0, min(controller.infoPanelHeight, controller.infoPanelHeight - dy))
                                }
                            } else {
                                if dy > 0 {
                                    controller.verticalDismissOffset = dy
                                    controller.infoPanelPullOffset = 0
                                    controller.backdropOpacity = max(0.15, 1.0 - (Double(dy) / 220.0) * 0.75)
                                } else if dy < 0 {
                                    controller.infoPanelPullOffset = max(0, min(controller.infoPanelHeight, -dy))
                                    controller.verticalDismissOffset = 0
                                    controller.backdropOpacity = 1.0
                                }
                            }
                        }
                    }
                }
                .onEnded { value in
                    if controller.zoomScale > 1.01 {
                        let finalX = controller.offset.width + value.translation.width
                        let finalY = controller.offset.height + value.translation.height
                        let fit = controller.fittedImageSize.width > 0 ? controller.fittedImageSize : controller.containerSize
                        let maxX = max(0, (fit.width * controller.zoomScale - controller.containerSize.width) / 2)
                        let maxY = max(0, (fit.height * controller.zoomScale - controller.containerSize.height) / 2)
                        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) {
                            controller.offset = CGSize(
                                width: min(max(finalX, -maxX), maxX),
                                height: min(max(finalY, -maxY), maxY)
                            )
                            controller.dragTranslation = .zero
                        }
                    } else {
                        guard !controller.isPinching, !controller.isAnimatingSlide, !controller.isFlyingToGrid else { return }
                        if controller.gestureAxis == .horizontal {
                            let velocityX = value.predictedEndTranslation.width - value.translation.width
                            let W = controller.containerSize.width > 0 ? controller.containerSize.width : 800
                            let commitThreshold = max(110.0, min(W * 0.18, 180.0))
                            let isFlickNext = (controller.slideOffset < -60.0 && velocityX < -20.0)
                            let isFlickPrev = (controller.slideOffset > 60.0 && velocityX > 20.0)
                            if (controller.slideOffset < -commitThreshold || isFlickNext) && controller.nextItem != nil {
                                controller.commitSlide(to: .next)
                            } else if (controller.slideOffset > commitThreshold || isFlickPrev) && controller.prevItem != nil {
                                controller.commitSlide(to: .previous)
                            } else {
                                controller.snapBackHorizontal()
                            }
                        } else if controller.gestureAxis == .vertical {
                            let velocityY = value.predictedEndTranslation.height - value.translation.height
                            if controller.isInfoPanelOpen {
                                if value.translation.height > 70 || velocityY > 150 {
                                    controller.commitCloseInfoPanel()
                                } else {
                                    controller.commitOpenInfoPanel()
                                }
                            } else {
                                if controller.verticalDismissOffset > 0 {
                                    let isFlickDismiss = (controller.verticalDismissOffset > 50 && velocityY > 150)
                                    if controller.verticalDismissOffset > 90 || isFlickDismiss {
                                        controller.commitDismissFlyToGrid()
                                    } else {
                                        controller.snapBackVertical()
                                    }
                                } else if controller.infoPanelPullOffset > 0 {
                                    let isFlickOpen = (controller.infoPanelPullOffset > 50 && velocityY < -150)
                                    if controller.infoPanelPullOffset > 80 || isFlickOpen {
                                        controller.commitOpenInfoPanel()
                                    } else {
                                        controller.snapBackVertical()
                                    }
                                } else {
                                    controller.snapBackVertical()
                                }
                            }
                        }
                        controller.gestureAxis = .uncommitted
                    }
                }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2)
                .onEnded { event in
                    controller.handleDoubleTap(at: event.location)
                }
        )
        .onAppear {
            controller.containerSize = containerSize
            if let image = controller.fullImage {
                controller.fittedImageSize = Self.aspectFitSize(of: image, in: containerSize)
            }
        }
        .onChange(of: containerSize) { _, newSize in
            controller.containerSize = newSize
            if let image = controller.fullImage {
                controller.fittedImageSize = Self.aspectFitSize(of: image, in: newSize)
            }
        }
        .onChange(of: controller.fullImage) { _, newImage in
            if let newImage, controller.containerSize.width > 0, controller.containerSize.height > 0 {
                controller.fittedImageSize = Self.aspectFitSize(of: newImage, in: controller.containerSize)
            }
        }
        .contextMenu {
            Button {
                ImageClipboard.copyImage(url: controller.currentItem.url)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            ShareLink(item: controller.currentItem.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([controller.currentItem.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Divider()

            AppPickerMenu(item: controller.currentItem)

            Divider()

            Button {
                if controller.isInfoPanelOpen {
                    controller.commitCloseInfoPanel()
                } else {
                    controller.commitOpenInfoPanel()
                }
            } label: {
                Label(controller.isInfoPanelOpen ? "Hide Info" : "Get Info", systemImage: "info.circle")
            }
        }
    }

    // MARK: - Map Style Zoom HUD

    private var mapStyleZoomHUD: some View {
        HStack(spacing: 8) {
            Button(action: { controller.zoomOut() }) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(controller.zoomScale <= controller.minZoom)
            .foregroundStyle(controller.zoomScale <= controller.minZoom ? Color.primary.opacity(0.25) : Color.primary)
            .help("Zoom Out (⌘-)")

            Slider(value: Binding(
                get: { Double(controller.zoomScale) },
                set: { newValue in
                    controller.applyZoom(targetScale: CGFloat(newValue), anchor: controller.mouseLocation, animated: false)
                }
            ), in: Double(controller.minZoom)...Double(controller.maxZoom))
            .frame(width: 100)
            .controlSize(.small)

            Button(action: { controller.zoomIn() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(controller.zoomScale >= controller.maxZoom)
            .foregroundStyle(controller.zoomScale >= controller.maxZoom ? Color.primary.opacity(0.25) : Color.primary)
            .help("Zoom In (⌘+)")

            Divider()
                .frame(height: 14)

            Button(action: { controller.resetZoom(animated: true) }) {
                Text(controller.zoomScale <= 1.01 ? "Fit" : "\(Int(controller.zoomScale * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .frame(minWidth: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset to Fit (⌘0)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private static func aspectFitSize(of image: NSImage, in container: CGSize) -> CGSize {
        var size = image.size
        if size.width <= 0 || size.height <= 0, let rep = image.representations.first {
            size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / size.width, container.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if !controller.isFullResLoaded {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
                Text("Loading full resolution")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
    }
}

// MARK: - Photo Info & Location Map Panel (Official Apple HIG Inspector)

enum MetadataTab: String, CaseIterable, Identifiable {
    case general = "General"
    case exif = "Exif"
    case gps = "GPS"
    case raw = "All Metadata"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "info.circle"
        case .exif: return "camera"
        case .gps: return "location"
        case .raw: return "list.bullet.rectangle"
        }
    }
}

struct PhotoInfoMapView: View {
    let item: ImageItem
    let metadata: PhotoMetadata?
    let onClose: () -> Void

    @State private var selectedTab: MetadataTab = .general
    @State private var searchTagText: String = ""
    @State private var selectedGroupFilter: String = "All"
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var copiedSummary: Bool = false
    @State private var copiedCoordinates: Bool = false
    @State private var copiedDimensions: Bool = false
    @State private var copiedPath: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Apple-style drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { val in
                            if val.translation.height > 25 {
                                onClose()
                            }
                        }
                )

            // Header Bar: Native Segmented Picker centered via ZStack, Stationary Title & Actions
            ZStack {
                // Center: Native Apple Segmented Control (Dead-center, perfectly stable)
                Picker("", selection: $selectedTab) {
                    ForEach(MetadataTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)

                // Edges: Left Title & Right Standard macOS Action Buttons
                HStack(alignment: .center, spacing: 12) {
                    // Left: Stationary "Info" Title (Does not jump or change width across tabs)
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Info")
                            .font(.headline.weight(.semibold))
                    }

                    Spacer()

                    // Right: Close Button
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc or ⌘I)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            Divider()

            // Content Views
            Group {
                switch selectedTab {
                case .general:
                    ScrollView(.vertical, showsIndicators: true) {
                        generalOverviewTabView
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                case .exif:
                    ScrollView(.vertical, showsIndicators: true) {
                        exifDetailsTabView
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                case .gps:
                    ScrollView(.vertical, showsIndicators: true) {
                        gpsLocationTabView
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                case .raw:
                    rawMetadataTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Tab 1: General (Two-Column Apple Photos Layout)

    @ViewBuilder
    private var generalOverviewTabView: some View {
        ViewThatFits(in: .horizontal) {
            // Wide layout: 2-Column Side-by-Side
            HStack(alignment: .top, spacing: 20) {
                leftInfoColumn
                    .frame(minWidth: 320, maxWidth: .infinity)

                rightMapAndActionsColumn
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 8)

            // Compact/Narrow layout: Vertically stacked
            VStack(alignment: .leading, spacing: 18) {
                leftInfoColumn
                rightMapAndActionsColumn
            }
            .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Left Column: Header, Camera Box & Technical Specs

    @ViewBuilder
    private var leftInfoColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Filename & Capture/Modification Date
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)

                Text(formattedDateString)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            // Signature Rounded Camera & Photo Info Box
            applePhotosCameraCard

            // Technical Specifications & File Details Card
            technicalSpecsCard
        }
    }

    // MARK: - Signature Camera & Photo Info Box

    @ViewBuilder
    private var applePhotosCameraCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Line 1: Camera Model
            HStack(alignment: .center) {
                Text(metadata?.formattedCamera ?? metadata?.cameraModel ?? "Camera")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }

            // Line 2: Lens Info (e.g. "Main Camera — 24 mm ƒ1.78" or Lens model)
            if let lensText = metadata?.formattedLensSubtitle ?? metadata?.lensModel {
                Text(lensText)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            // Line 3: Megapixels, Dimensions, File Size, and Format Pill
            HStack(alignment: .center, spacing: 14) {
                if let mp = metadata?.formattedMegapixelsApple {
                    Text(mp)
                }
                if let dim = metadata?.formattedDimensions {
                    Text(dim)
                }
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))

                Spacer()

                // Format badge [HEIF], [JPEG], [RAW], [PNG]
                Text(item.url.pathExtension.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .secondaryLabelColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 3.5))
                    .foregroundStyle(.primary)
            }
            .font(.system(size: 12.5, weight: .regular))
            .foregroundStyle(.primary)
            .padding(.top, 3)

            // Inner Divider
            Divider()
                .opacity(0.4)
                .padding(.vertical, 8)

            // Line 4: Exposure parameters evenly spaced across card
            HStack(alignment: .center) {
                Text(metadata?.formattedISO ?? "ISO —")
                Spacer()
                Text(metadata?.formattedFocalLengthApple ?? "— mm")
                Spacer()
                Text(metadata?.formattedExposureBiasApple ?? "0 ev")
                Spacer()
                Text(metadata?.formattedApertureApple ?? "ƒ/—")
                Spacer()
                Text(metadata?.formattedExposure ?? "— s")
            }
            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
    }

    // MARK: - Technical Specifications Card

    @ViewBuilder
    private var technicalSpecsCard: some View {
        VStack(spacing: 0) {
            appleInspectorRow(
                label: "Dimensions",
                value: (metadata?.formattedDimensions ?? "—") + (metadata?.formattedMegapixelsApple.map { "  •  \($0)" } ?? "")
            )
            Divider().padding(.leading, 115).padding(.trailing, 10)

            appleInspectorRow(
                label: "Resolution",
                value: metadata?.formattedDPI ?? "72 DPI"
            )
            Divider().padding(.leading, 115).padding(.trailing, 10)

            appleInspectorRow(
                label: "Color Profile",
                value: metadata?.colorProfile ?? "Display P3 / sRGB"
            )
            Divider().padding(.leading, 115).padding(.trailing, 10)

            appleInspectorRow(
                label: "Color Space",
                value: (metadata?.colorModel ?? "RGB") + (metadata?.depth.map { " (\($0)-bit)" } ?? "")
            )

            if let orientation = metadata?.orientation {
                Divider().padding(.leading, 115).padding(.trailing, 10)
                appleInspectorRow(
                    label: "Orientation",
                    value: orientation
                )
            }

            Divider().padding(.leading, 115).padding(.trailing, 10)

            appleInspectorRow(
                label: "File Size",
                value: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file) + " (\(item.size.formatted()) bytes)"
            )

            Divider().padding(.leading, 115).padding(.trailing, 10)

            appleInspectorRow(
                label: "Format",
                value: "\(item.url.pathExtension.uppercased())  •  \(item.typeIdentifier)"
            )

            if let modDate = item.modificationDate {
                Divider().padding(.leading, 115).padding(.trailing, 10)
                appleInspectorRow(
                    label: "Modified",
                    value: modDate.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Divider().padding(.leading, 115).padding(.trailing, 10)

            // Where / File Path Row
            HStack(alignment: .center, spacing: 8) {
                Text("Where")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 105, alignment: .leading)

                Text(item.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer(minLength: 4)

                Button {
                    copyToClipboard(item.path)
                    copiedPath = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedPath = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                        Text(copiedPath ? "Copied" : "Copy")
                    }
                    .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Copy file path")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Reveal in Finder")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
    }

    // MARK: - Right Column: Location Header, Embedded Map & Action Pills

    @ViewBuilder
    private var rightMapAndActionsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Location Header: Placename + Coordinates
            VStack(alignment: .leading, spacing: 2) {
                Text(locationTitleText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(metadata?.hasLocation == true ? .primary : .secondary)
                    .lineLimit(1)

                if let coordStr = metadata?.formattedCoordinatesDMS ?? metadata?.formattedCoordinatesDecimal {
                    HStack(spacing: 6) {
                        Text(coordStr)
                        if let alt = metadata?.formattedAltitude {
                            Text("•").foregroundStyle(.tertiary)
                            Text(alt)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)

            // Embedded Apple Map
            if let coord = metadata?.coordinate {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                ))) {
                    Marker(metadata?.placename ?? item.name, coordinate: coord)
                        .tint(.red)
                }
                .id("\(coord.latitude),\(coord.longitude)")
                .mapStyle(.standard(elevation: .realistic))
                .frame(minHeight: 190, idealHeight: 215, maxHeight: 235)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                )
            } else {
                // Empty state when photo has no GPS
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No Location Information")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("This photo does not contain GPS metadata.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 190, idealHeight: 215)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                )
            }

            // Action Pills Grid (2x2)
            applePhotosActionPillsGrid
        }
    }

    // MARK: - Action Pills Grid (2x2 rounded buttons conforming to macOS HIG)

    @ViewBuilder
    private var applePhotosActionPillsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
        let coord = metadata?.coordinate

        LazyVGrid(columns: columns, spacing: 10) {
            // Pill 1: Open in Apple Maps
            ApplePillButton(icon: "map", title: "Open in Maps", iconTint: coord != nil ? .blue : .secondary) {
                if let coord { openInAppleMaps(coordinate: coord) }
            }
            .disabled(coord == nil)

            // Pill 2: Copy Coordinates
            ApplePillButton(icon: "mappin.and.ellipse", title: copiedCoordinates ? "Copied!" : "Coordinates", iconTint: coord != nil ? .red : .secondary, isCopied: copiedCoordinates) {
                if let coord {
                    let coordsText = metadata?.formattedCoordinatesDecimal ?? "\(coord.latitude), \(coord.longitude)"
                    copyToClipboard(coordsText)
                    copiedCoordinates = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedCoordinates = false }
                }
            }
            .disabled(coord == nil)

            // Pill 3: Reveal in Finder
            ApplePillButton(icon: "folder", title: "Reveal in Finder", iconTint: .blue) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }

            // Pill 4: Copy File Path
            ApplePillButton(icon: "doc.on.doc", title: copiedPath ? "Copied!" : "Copy Path", iconTint: .secondary, isCopied: copiedPath) {
                copyToClipboard(item.path)
                copiedPath = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedPath = false }
            }
        }
    }

    private var formattedDateString: String {
        guard let date = metadata?.captureDate ?? item.modificationDate else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private var locationTitleText: String {
        if let place = metadata?.placename, !place.isEmpty {
            return place
        } else if let coordDMS = metadata?.formattedCoordinatesDMS {
            return coordDMS
        } else {
            return "No Location Information"
        }
    }

    // MARK: - Tab 2: Exif (Photographic Inspector)

    @ViewBuilder
    private var exifDetailsTabView: some View {
        ViewThatFits(in: .horizontal) {
            // Wide layout: 2-Column Side-by-Side
            HStack(alignment: .top, spacing: 20) {
                exifCameraEquipmentSection
                    .frame(minWidth: 320, maxWidth: .infinity)

                exifExposureOpticsSection
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 8)

            // Compact/Narrow layout: Vertically stacked
            VStack(alignment: .leading, spacing: 18) {
                exifCameraEquipmentSection
                exifExposureOpticsSection
            }
            .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var exifCameraEquipmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera & Lens")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                appleInspectorRow(label: "Camera Make", value: metadata?.cameraMake ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Camera Model", value: metadata?.cameraModel ?? metadata?.formattedCamera ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Lens Model", value: metadata?.lensModel ?? metadata?.lensMake ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Software", value: metadata?.software ?? "—")
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var exifExposureOpticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Exposure & Optics")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                appleInspectorRow(
                    label: "Focal Length",
                    value: (metadata?.formattedFocalLength ?? "—") + (metadata?.focalLength35mm.map { " (\(Int($0)) mm 35mm equivalent)" } ?? "")
                )
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Aperture", value: metadata?.formattedAperture ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Shutter Speed", value: metadata?.formattedExposure ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "ISO Rating", value: metadata?.formattedISO ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Exposure Bias", value: metadata?.formattedExposureBias ?? "0 EV")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Exposure Program", value: metadata?.exposureProgram ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Metering Mode", value: metadata?.meteringMode ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "White Balance", value: metadata?.whiteBalance ?? "—")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Flash", value: metadata?.flash ?? "—")
                if let dz = metadata?.digitalZoomRatio, dz > 1.0 {
                    Divider().padding(.leading, 120)
                    appleInspectorRow(label: "Digital Zoom", value: String(format: "%.1f×", dz))
                }
                if let orientation = metadata?.orientation {
                    Divider().padding(.leading, 120)
                    appleInspectorRow(label: "Orientation", value: orientation)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    // MARK: - Tab 3: GPS (Location Inspector)

    @ViewBuilder
    private var gpsLocationTabView: some View {
        if let coord = metadata?.coordinate {
            ViewThatFits(in: .horizontal) {
                // Wide layout: 2-Column Side-by-Side
                HStack(alignment: .top, spacing: 20) {
                    gpsMapSection(coord: coord)
                        .frame(minWidth: 320, maxWidth: .infinity)

                    gpsDetailsAndActionsSection(coord: coord)
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
                .frame(maxWidth: 1100)
                .padding(.horizontal, 8)

                // Compact/Narrow layout: Vertically stacked
                VStack(alignment: .leading, spacing: 14) {
                    gpsMapSection(coord: coord)
                    gpsDetailsAndActionsSection(coord: coord)
                }
                .frame(maxWidth: 540)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            ContentUnavailableView {
                Label("No Location Information", systemImage: "mappin.slash")
            } description: {
                Text("This photo doesn't contain GPS coordinates. Location data is typically embedded by cameras and phones at the time a photo is taken.")
            }
            .frame(maxWidth: 1100, minHeight: 260)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func gpsMapSection(coord: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Map Location")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Map(initialPosition: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            ))) {
                Marker(item.name, coordinate: coord)
                    .tint(.red)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
            .frame(minHeight: 240, idealHeight: 260, maxHeight: 300)
        }
    }

    @ViewBuilder
    private func gpsDetailsAndActionsSection(coord: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coordinates & Telemetry")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                if let place = metadata?.placename {
                    appleInspectorRow(label: "Location", value: place)
                    Divider().padding(.leading, 120)
                }
                appleInspectorRow(label: "Latitude", value: "\(coord.latitude)° (\(metadata?.formattedCoordinatesDMS ?? ""))")
                Divider().padding(.leading, 120)
                appleInspectorRow(label: "Longitude", value: "\(coord.longitude)°")
                if let alt = metadata?.formattedAltitude {
                    Divider().padding(.leading, 120)
                    appleInspectorRow(label: "Altitude", value: alt)
                }
                if let sp = metadata?.formattedSpeed {
                    Divider().padding(.leading, 120)
                    appleInspectorRow(label: "Speed", value: sp)
                }
                if let dir = metadata?.formattedDirection {
                    Divider().padding(.leading, 120)
                    appleInspectorRow(label: "Heading", value: dir)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))

            // Actions
            HStack(spacing: 12) {
                Button {
                    openInAppleMaps(coordinate: coord)
                } label: {
                    Label("Open in Apple Maps", systemImage: "map")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    let link = "https://maps.apple.com/?q=\(coord.latitude),\(coord.longitude)"
                    copyToClipboard(link)
                    copiedCoordinates = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedCoordinates = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedCoordinates ? "checkmark" : "link")
                        Text(copiedCoordinates ? "Link Copied" : "Copy Maps Link")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Tab 4: All Metadata (Authentic Apple Inspector Table)

    @ViewBuilder
    private var rawMetadataTabView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned Search & Filter Controls
            HStack(spacing: 10) {
                // Native Search Field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchTagText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !searchTagText.isEmpty {
                        Button {
                            searchTagText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                // Category Filter Menu
                if let groups = metadata?.rawGroups, groups.count > 1 {
                    Menu {
                        Button("All Categories") { selectedGroupFilter = "All" }
                        Divider()
                        ForEach(groups) { group in
                            Button("\(group.name) (\(group.items.count))") {
                                selectedGroupFilter = group.name
                            }
                        }
                    } label: {
                        Text(selectedGroupFilter == "All" ? "All Groups" : selectedGroupFilter)
                            .font(.system(size: 11.5))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                }

                Spacer()

                // Tag count indicator
                if let groups = metadata?.rawGroups {
                    let totalTags = groups.reduce(0) { $0 + $1.items.count }
                    let filteredCount = filterGroups(groups).reduce(0) { $0 + $1.items.count }
                    Text(searchTagText.isEmpty && selectedGroupFilter == "All" ? "\(totalTags) tags" : "\(filteredCount) of \(totalTags) tags")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Expand / Collapse All
                Button {
                    toggleExpandCollapseAll()
                } label: {
                    Image(systemName: areAllCollapsed ? "chevron.down.circle" : "chevron.up.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(areAllCollapsed ? "Expand all sections" : "Collapse all sections")
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Column Header
            HStack(spacing: 12) {
                Text("Tag")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 240, alignment: .leading)

                Text("Value")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))

            Divider()

            // Native Scrollable Raw Table
            ScrollView(.vertical, showsIndicators: true) {
                rawTagsListContent
                    .frame(maxWidth: 1100)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var rawTagsListContent: some View {
        if let groups = metadata?.rawGroups, !groups.isEmpty {
            let filteredGroups = filterGroups(groups)
            if filteredGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No metadata matches \"\(searchTagText)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            // Section Header Button
                            Button {
                                withAnimation(.snappy(duration: 0.16)) {
                                    if collapsedGroupIDs.contains(group.id) {
                                        collapsedGroupIDs.remove(group.id)
                                    } else {
                                        collapsedGroupIDs.insert(group.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsedGroupIDs.contains(group.id) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 10)

                                    Text(group.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text("\(group.items.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)

                            // Rows
                            if !collapsedGroupIDs.contains(group.id) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, tag in
                                        AppleInspectorTagRow(tag: tag, isEven: index.isMultiple(of: 2))

                                        if index < group.items.count - 1 {
                                            Divider()
                                                .opacity(0.3)
                                        }
                                    }
                                }
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                )
                                .padding(.top, 2)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private var areAllCollapsed: Bool {
        guard let groups = metadata?.rawGroups, !groups.isEmpty else { return false }
        return collapsedGroupIDs.count >= groups.count
    }

    private func toggleExpandCollapseAll() {
        guard let groups = metadata?.rawGroups else { return }
        withAnimation(.snappy(duration: 0.2)) {
            if areAllCollapsed {
                collapsedGroupIDs.removeAll()
            } else {
                collapsedGroupIDs = Set(groups.map { $0.id })
            }
        }
    }

    private func filterGroups(_ groups: [RawMetadataGroup]) -> [RawMetadataGroup] {
        var baseGroups = groups
        if selectedGroupFilter != "All" {
            baseGroups = groups.filter { $0.name == selectedGroupFilter }
        }
        guard !searchTagText.isEmpty else { return baseGroups }
        let query = searchTagText.lowercased()
        return baseGroups.compactMap { group in
            let filtered = group.items.filter { item in
                item.key.lowercased().contains(query) || item.value.lowercased().contains(query)
            }
            if filtered.isEmpty && !group.name.lowercased().contains(query) {
                return nil
            }
            return RawMetadataGroup(id: group.id, name: group.name, items: filtered.isEmpty ? group.items : filtered)
        }
    }

    // MARK: - Apple HIG Helper Rows

    private func appleInspectorRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func openInAppleMaps(coordinate: CLLocationCoordinate2D) {
        let name = (metadata?.placename ?? item.name).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "maps://?ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(name)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Apple Inspector Tag Row with Clean Hover Copy

struct AppleInspectorTagRow: View {
    let tag: RawMetadataItem
    let isEven: Bool
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(tag.key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 240, alignment: .leading)
                .textSelection(.enabled)

            Text(tag.value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Button {
                let pboard = NSPasteboard.general
                pboard.clearContents()
                pboard.setString("\(tag.key): \(tag.value)", forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5))
                    .foregroundStyle(copied ? Color.green : (isHovered ? Color.primary : Color.clear))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied tag to clipboard!" : "Copy tag name & value")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4.5)
        .background(isHovered ? Color.primary.opacity(0.04) : (isEven ? Color.clear : Color.primary.opacity(0.015)))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Apple Pill Button (macOS HIG Utility Chip)

struct ApplePillButton: View {
    let icon: String
    let title: String
    var iconTint: Color = .secondary
    var isCopied: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isCopied ? "checkmark" : icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isCopied ? Color.green : iconTint)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                isHovered
                    ? Color(nsColor: .controlBackgroundColor).opacity(0.95)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.75),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isHovered
                            ? Color(nsColor: .separatorColor).opacity(0.8)
                            : Color(nsColor: .separatorColor).opacity(0.4),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

