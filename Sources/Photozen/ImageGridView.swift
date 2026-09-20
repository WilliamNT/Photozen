import SwiftUI

struct ImageGridView: View {
    @EnvironmentObject var model: PhotozenModel
    @Binding var selectedImageID: UUID?
    @Binding var columnsPerRow: Int
    let onOpenViewer: (ImageItem) -> Void

    @State private var baseGridZoom: Double = 1.0

    var body: some View {
        Group {
            if model.selectedRoot == nil {
                emptyState
            } else if model.isScanning {
                scanningState
            } else if let error = model.scanError, model.images.isEmpty {
                errorState(error)
            } else if model.filteredImages.isEmpty {
                noImagesState
            } else {
                PhotoGrid(
                    groups: model.dateGroups,
                    selectedImageID: $selectedImageID,
                    columnsPerRow: $columnsPerRow,
                    onOpenViewer: onOpenViewer
                )
            }
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let target = baseGridZoom * Double(value)
                    model.filter.zoomLevel = min(max(target, 1.0), 4.0)
                }
                .onEnded { _ in
                    baseGridZoom = model.filter.zoomLevel
                }
        )
        .onAppear {
            baseGridZoom = model.filter.zoomLevel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Library Selected", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add a folder, drive, or network share to start browsing your images.")
        } actions: {
            Button("Add Folder…") {
                model.addFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    private var scanningState: some View {
        ContentUnavailableView {
            Label("Indexing “\(model.currentTitle)”", systemImage: "photo.stack")
        } description: {
            Text(model.indexedCount == 0 ? "Scanning directories and reading metadata…" : "\(model.indexedCount) photos found so far…")
        } actions: {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 220)
                .controlSize(.regular)
                .padding(.top, 4)
        }
    }

    private func errorState(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Can’t Access Location", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Try Again") {
                model.rescanSelected()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var noImagesState: some View {
        if !model.filter.text.isEmpty {
            ContentUnavailableView.search(text: model.filter.text)
        } else if model.hasAnyImages {
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text("No photos match the current filters.")
            }
        } else {
            ContentUnavailableView {
                Label("No Photos", systemImage: "photo.on.rectangle")
            } description: {
                Text("This location doesn’t contain any image files.")
            }
        }
    }
}

struct PhotoGrid: View {
    let groups: [DateGroup]
    @Binding var selectedImageID: UUID?
    @Binding var columnsPerRow: Int
    let onOpenViewer: (ImageItem) -> Void
    @EnvironmentObject var model: PhotozenModel

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                GridContentView(
                                    items: group.items,
                                    selectedImageID: $selectedImageID,
                                    onOpenViewer: onOpenViewer
                                )
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 24)
                            } header: {
                                HStack {
                                    Text(group.title)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(group.items.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial)
                                .overlay(alignment: .bottom) {
                                    Divider()
                                        .opacity(0.4)
                                }
                                .id("header-\(group.id)")
                            }
                        }

                        // Apple Photos style library status footer at bottom of scroll view
                        VStack(spacing: 4) {
                            Text(model.filteredImages.count == 1 ? "1 Photo" : "\(model.filteredImages.count) Photos")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)

                            if model.isRefreshing {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Indexing changes…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(relativeUpdateText(now: context.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                }
                .onChange(of: selectedImageID) {
                    if let id = selectedImageID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onAppear {
                updateColumnCount(width: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                updateColumnCount(width: newWidth)
            }
            .onChange(of: model.filter.zoomLevel) { _, _ in
                updateColumnCount(width: geometry.size.width)
            }
        }
    }

    private func updateColumnCount(width: CGFloat) {
        let cellSize = 100 + (model.filter.zoomLevel - 1.0) * 120
        let spacing: CGFloat = 12
        let horizontalPadding: CGFloat = 40
        let available = max(0, width - horizontalPadding)
        let count = max(1, Int((available + spacing) / (cellSize + spacing)))
        columnsPerRow = count
    }

    private func relativeUpdateText(now: Date) -> String {
        guard let lastUpdated = model.lastUpdated else {
            return "Updated Just Now"
        }
        let elapsed = now.timeIntervalSince(lastUpdated)
        if elapsed < 60 {
            return "Updated Just Now"
        } else if elapsed < 3600 {
            let mins = Int(elapsed / 60)
            return "Updated \(mins) min\(mins == 1 ? "" : "s") ago"
        } else if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            return "Updated \(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(elapsed / 86400)
            return "Updated \(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

struct GridContentView: View {
    let items: [ImageItem]
    @Binding var selectedImageID: UUID?
    let onOpenViewer: (ImageItem) -> Void
    @EnvironmentObject var model: PhotozenModel

    var body: some View {
        let cellSize = gridSize(for: model.filter.zoomLevel)
        let columns = [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.4), spacing: 12)]

        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { item in
                ImageCellView(
                    item: item,
                    isSelected: selectedImageID == item.id,
                    onOpen: {
                        onOpenViewer(item)
                    },
                    onSelect: {
                        selectedImageID = item.id
                    }
                )
                .id(item.id)
            }
        }
    }

    private func gridSize(for zoom: Double) -> CGFloat {
        100 + (zoom - 1.0) * 120
    }
}
