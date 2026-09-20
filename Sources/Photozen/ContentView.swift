import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: PhotozenModel
    @State private var selectedImageID: UUID?
    @State private var viewerItem: ImageItem?
    @State private var gridColumnsPerRow = 6
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var isSearchPresented = false
    @State private var isFullScreen = false
    @State private var cursorHideTask: Task<Void, Never>?
    @FocusState private var isDetailFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            ZStack {
                ImageGridView(
                    selectedImageID: $selectedImageID,
                    columnsPerRow: $gridColumnsPerRow,
                    onOpenViewer: { newItem in
                        selectedImageID = newItem.id
                        viewerItem = newItem
                    }
                )
                .allowsHitTesting(viewerItem == nil)

                if let item = viewerItem {
                    ImageViewerView(
                        items: model.filteredImages,
                        selectedItem: item,
                        targetGridRect: cellFrames[item.id],
                        isInfoPanelOpen: $model.isInfoOpen,
                        onClose: { viewerItem = nil },
                        onSelectionChanged: { newItem in
                            selectedImageID = newItem.id
                            viewerItem = newItem
                        }
                    )
                    .transition(.opacity)
                }

                if model.showKeyboardShortcuts {
                    KeyboardShortcutsOverlay(isPresented: $model.showKeyboardShortcuts)
                        .zIndex(100)
                }
            }
            .coordinateSpace(name: "viewerSpace")
            .onPreferenceChange(GridCellFramesKey.self) { frames in
                cellFrames = frames
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isDetailFocused)
        }
        .navigationTitle(fullScreenViewer ? "" : (viewerItem != nil ? viewerItem!.name : model.currentTitle))
        .navigationSubtitle(fullScreenViewer ? "" : navigationSubtitleText)
        .searchable(text: $model.filter.text, isPresented: $isSearchPresented, placement: .toolbar, prompt: "Search Photos")
        .onChange(of: model.searchFocusTrigger) { _, _ in
            activateSearch()
        }
        .onChange(of: model.sidebarSelection) { _, newSelection in
            if case .image(_, let item) = newSelection {
                selectedImageID = item.id
                viewerItem = item
            }
        }
        .background {
            Group {
                Button("") {
                    if let viewerItem {
                        ImageClipboard.copyImage(url: viewerItem.url)
                    } else if let id = selectedImageID,
                              let item = model.filteredImages.first(where: { $0.id == id }) {
                        ImageClipboard.copyImage(url: item.url)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("") {
                    activateSearch()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("") {
                    if let viewerItem {
                        printImage(url: viewerItem.url)
                    } else if let id = selectedImageID,
                              let item = model.filteredImages.first(where: { $0.id == id }) {
                        printImage(url: item.url)
                    }
                }
                .keyboardShortcut("p", modifiers: [.command])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .onAppear {
            isDetailFocused = true
        }
        .onChange(of: viewerItem) { _, newItem in
            if let newItem {
                model.printableImageURL = newItem.url
            } else if let id = selectedImageID,
                      let item = model.filteredImages.first(where: { $0.id == id }) {
                model.printableImageURL = item.url
            } else {
                model.printableImageURL = nil
            }
        }
        .onChange(of: selectedImageID) { _, newID in
            if viewerItem == nil {
                if let id = newID, let item = model.filteredImages.first(where: { $0.id == id }) {
                    model.printableImageURL = item.url
                } else {
                    model.printableImageURL = nil
                }
            }
        }
        .onKeyPress(.return) {
            if viewerItem == nil, selectedImageID != nil {
                openSelected()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            if viewerItem != nil {
                viewerItem = nil
            } else if let id = selectedImageID,
                      let item = model.filteredImages.first(where: { $0.id == id }) {
                selectedImageID = item.id
                viewerItem = item
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if isSearchPresented && !model.filter.text.isEmpty {
                model.filter.text = ""
                return .handled
            }
            if fullScreenViewer {
                toggleFullScreen()
                return .handled
            }
            if viewerItem != nil {
                viewerItem = nil
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            if let item = viewerItem {
                navigateBy(-gridColumnsPerRow, from: item)
            } else {
                moveSelection(-gridColumnsPerRow)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if let item = viewerItem {
                navigateBy(gridColumnsPerRow, from: item)
            } else {
                moveSelection(gridColumnsPerRow)
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if let item = viewerItem {
                navigateBy(-1, from: item)
            } else {
                moveSelection(-1)
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if let item = viewerItem {
                navigateBy(1, from: item)
            } else {
                moveSelection(1)
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "f")) { _ in
            if viewerItem != nil {
                toggleFullScreen()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "?")) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                model.showKeyboardShortcuts.toggle()
            }
            return .handled
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if viewerItem != nil {
                    Button {
                        viewerItem = nil
                    } label: {
                        Label(model.currentTitle, systemImage: "chevron.backward")
                    }
                    .help("Back to \(model.currentTitle)")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if let item = viewerItem {
                    viewerToolbar(for: item)
                } else if model.selectedRoot != nil {
                    zoomControls
                    sortControls
                    refreshButton
                } else {
                    addFolderButton
                }
            }
        }
        .toolbar(fullScreenViewer ? .hidden : .automatic, for: .windowToolbar)
        .animation(.easeOut(duration: 0.12), value: viewerItem)
        .onChange(of: model.presentFolderPicker) { _, isPresented in
            if isPresented {
                model.presentFolderPicker = false
                model.addFolder()
            }
        }
        .onChange(of: model.filteredImages) { _, newImages in
            if let current = viewerItem, !newImages.contains(where: { $0.id == current.id }) {
                viewerItem = nil
            }
        }
        .onChange(of: fullScreenViewer) { _, isActive in
            if isActive {
                scheduleCursorHide()
            } else {
                cursorHideTask?.cancel()
                NSCursor.setHiddenUntilMouseMoves(false)
            }
        }
        .onContinuousHover { phase in
            if fullScreenViewer {
                switch phase {
                case .active:
                    NSCursor.setHiddenUntilMouseMoves(false)
                    scheduleCursorHide()
                case .ended:
                    break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if let window = notification.object as? NSWindow, window == NSApp.keyWindow {
                isFullScreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if let window = notification.object as? NSWindow, window == NSApp.keyWindow {
                isFullScreen = false
            }
        }
    }

    /// Whether the viewer is active in full-screen mode (immersive photo viewing)
    private var fullScreenViewer: Bool {
        isFullScreen && viewerItem != nil
    }

    private var navigationSubtitleText: String {
        if model.isRefreshing {
            return "Indexing changes…"
        }
        if let item = viewerItem {
            if let date = item.modificationDate {
                return date.formatted(date: .abbreviated, time: .shortened)
            }
            return ""
        }
        let count = model.filteredImages.count
        if count == 0 {
            return ""
        } else if count == 1 {
            return "1 photo"
        } else {
            return "\(count) photos"
        }
    }

    private func openSelected() {
        guard let id = selectedImageID,
              let item = model.filteredImages.first(where: { $0.id == id }) else { return }
        viewerItem = item
    }

    private func printImage(url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
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

    private func toggleFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        window.toggleFullScreen(nil)
    }

    private func scheduleCursorHide() {
        cursorHideTask?.cancel()
        cursorHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, fullScreenViewer else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func activateSearch() {
        if viewerItem != nil {
            viewerItem = nil
        }
        isSearchPresented = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusSearchFieldInActiveWindow()
        }
    }

    private func focusSearchFieldInActiveWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        let root = window.contentView?.superview ?? window.contentView
        func findSearchField(in view: NSView?) -> NSSearchField? {
            guard let view else { return nil }
            if let sf = view as? NSSearchField { return sf }
            for sub in view.subviews {
                if let found = findSearchField(in: sub) { return found }
            }
            return nil
        }
        if let sf = findSearchField(in: root) {
            window.makeFirstResponder(sf)
            sf.selectText(nil)
        }
    }

    private func moveSelection(_ delta: Int) {
        let items = model.filteredImages
        guard let currentID = selectedImageID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            if let first = items.first {
                selectedImageID = first.id
            }
            return
        }

        let newIndex = max(0, min(currentIndex + delta, items.count - 1))
        selectedImageID = items[newIndex].id
    }

    private func navigateBy(_ delta: Int, from item: ImageItem) {
        let items = model.filteredImages
        guard let currentIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        let newIndex = max(0, min(currentIndex + delta, items.count - 1))
        selectedImageID = items[newIndex].id
        viewerItem = items[newIndex]
    }

    private func viewerToolbar(for item: ImageItem) -> some View {
        HStack(spacing: 8) {
            Button {
                navigateBy(-1, from: item)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.filteredImages.first?.id == item.id)
            .help("Previous Photo (←)")

            Button {
                navigateBy(1, from: item)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.filteredImages.last?.id == item.id)
            .help("Next Photo (→)")

            Button {
                model.isInfoOpen.toggle()
            } label: {
                Image(systemName: model.isInfoOpen ? "info.circle.fill" : "info.circle")
            }
            .help("Get Info (⌘I)")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")

            AppPickerMenu(item: item)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    model.filter.zoomLevel = max(model.filter.zoomLevel - 0.5, 1.0)
                }
            } label: {
                Image(systemName: "minus")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(model.filter.zoomLevel <= 1.0)
            .help("Zoom Out (⌘-)")

            Slider(value: $model.filter.zoomLevel, in: 1.0...4.0) { }
                .frame(width: 80)
                .controlSize(.small)

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    model.filter.zoomLevel = min(model.filter.zoomLevel + 0.5, 4.0)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(model.filter.zoomLevel >= 4.0)
            .help("Zoom In (⌘+)")
        }
        .help("Zoom (⌘- / ⌘+)")
    }

    private var sortControls: some View {
        Menu {
            Picker("Sort By", selection: $model.filter.sortByDate) {
                Label("Date", systemImage: "calendar").tag(true)
                Label("Name", systemImage: "textformat").tag(false)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort by Date or Name")
    }

    private var refreshButton: some View {
        Button {
            model.refreshSelected()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(model.isScanning || model.isRefreshing)
        .help("Refresh Library (⌘R)")
    }

    private var addFolderButton: some View {
        Button {
            model.addFolder()
        } label: {
            Label("Add Folder", systemImage: "plus.circle")
        }
        .help("Add a folder, external drive, or network share")
    }
}
