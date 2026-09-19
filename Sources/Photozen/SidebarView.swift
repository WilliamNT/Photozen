import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: PhotozenModel

    var body: some View {
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { model.setSidebarSelection($0) }
        )) {
            Section {
                ForEach(model.locations) { location in
                    LocationRow(location: location)
                }
            } header: {
                HStack {
                    Text("Library & Locations")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.addFolder()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Add Library or Folder…")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .center) {
                    Button {
                        model.addFolder()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Text("Add Location…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Add a Photos Library, folder, external drive, or network share")

                    Spacer()

                    if model.isScanning || model.isRefreshing {
                        HStack(spacing: 5) {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 14, height: 14)
                            Text("Indexing…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if model.hasAnyImages {
                        Text("\(model.images.count) photos")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        .overlay {
            if model.locations.isEmpty {
                ContentUnavailableView {
                    Label("No Locations Added", systemImage: "photo.stack")
                } description: {
                    Text("Add an Apple Photos Library, folder,\nexternal drive, or network share.")
                } actions: {
                    Button("Add Library or Folder…") {
                        model.addFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .contextMenu(forSelectionType: SidebarSelection.self) { items in
            if let first = items.first {
                switch first {
                case .location(let id):
                    Button {
                        Task { await model.disconnect(locationID: id) }
                    } label: {
                        Label("Remove from Library", systemImage: "folder.badge.minus")
                    }
                case .subfolder(_, let path):
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                case .image(_, let item):
                    Button {
                        ImageClipboard.copyImage(url: item.url)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: item.url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    Divider()
                    AppPickerMenu(item: item)
                }
            }
        }
    }
}

struct LocationRow: View {
    @EnvironmentObject var model: PhotozenModel
    @StateObject private var node: FolderNode
    let location: FolderLocation

    init(location: FolderLocation) {
        self.location = location
        _node = StateObject(wrappedValue: FolderNode(
            url: location.url,
            depth: 0,
            isRoot: true,
            rootLocationID: location.id,
            kind: location.kind,
            isVolatile: location.isVolatile,
            status: location.status
        ))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $node.isExpanded) {
            if node.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            } else {
                ForEach(node.children) { child in
                    SubfolderRow(node: child)
                }
                ForEach(node.imageItems) { image in
                    SidebarImageRow(item: image, locationID: location.id, depth: 1)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: FolderIconProvider.shared.icon(for: location))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(location.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(subtitleText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(location.status == .missing ? .orange : .secondary)
                }

                Spacer()

                if location.status == .missing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("This location is offline or unavailable")
                } else if model.isScanning && model.selectedRootID == location.id {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                        .help("Scanning for photos…")
                } else if let count = model.photoCount(for: location.id), count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .contentShape(Rectangle())
        }
        .tag(SidebarSelection.location(location.id))
        .onChange(of: node.isExpanded) { _, expanded in
            if expanded {
                Task { await node.loadChildren() }
            }
        }
        .onChange(of: location.status) { _, newStatus in
            node.status = newStatus
            if newStatus == .missing {
                node.refreshAvailability()
            }
        }
        .onAppear {
            node.status = location.status
            if location.status == .missing {
                node.refreshAvailability()
            }
        }
        .contextMenu {
            Button {
                Task { await model.disconnect(locationID: location.id) }
            } label: {
                Label("Remove from Library", systemImage: "folder.badge.minus")
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path)
            }
        }
    }

    private var subtitleText: String {
        if location.status == .missing {
            return "Offline • Unavailable"
        }
        let lower = location.path.lowercased()
        if lower.hasSuffix(".photoslibrary") || lower.contains("photos library") {
            return "Photos Library"
        }
        if lower.contains("photo booth") {
            return "Photo Booth Library"
        }
        return location.kind.label
    }
}

struct SubfolderRow: View {
    @ObservedObject var node: FolderNode

    var body: some View {
        DisclosureGroup(isExpanded: $node.isExpanded) {
            if node.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(28 + node.depth * 14))
            } else {
                ForEach(node.children) { child in
                    SubfolderRow(node: child)
                }
                ForEach(node.imageItems) { image in
                    SidebarImageRow(item: image, locationID: node.rootLocationID, depth: node.depth + 1)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(nsImage: FolderIconProvider.shared.icon(forPath: node.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)

                Text(node.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)

                Spacer()

                if node.childrenLoaded && (node.children.count + node.imageItems.count) > 0 {
                    Text("\(node.imageItems.count > 0 ? "\(node.imageItems.count)" : "\(node.children.count)")")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, CGFloat(node.depth * 8))
            .contentShape(Rectangle())
        }
        .tag(SidebarSelection.subfolder(locationID: node.rootLocationID, path: node.url.path))
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.url.path)
            }
        }
        .onChange(of: node.isExpanded) { _, expanded in
            if expanded {
                Task { await node.loadChildren() }
            }
        }
    }
}

struct SidebarImageRow: View {
    let item: ImageItem
    let locationID: UUID
    var depth: Int = 1
    @EnvironmentObject var model: PhotozenModel
    @State private var thumbnail: NSImage? = nil

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 16, height: 16)
                        Image(systemName: "photo")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 16, height: 16)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(item.url.pathExtension.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 2.5))
        }
        .padding(.leading, CGFloat(depth * 8))
        .contentShape(Rectangle())
        .tag(SidebarSelection.image(locationID: locationID, item: item))
        .task(id: item.path) {
            let thumb = await ThumbnailProvider.shared.thumbnail(path: item.path)
            guard !Task.isCancelled else { return }
            thumbnail = thumb
        }
        .contextMenu {
            Button {
                ImageClipboard.copyImage(url: item.url)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            ShareLink(item: item.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Divider()

            AppPickerMenu(item: item)
        }
    }
}
