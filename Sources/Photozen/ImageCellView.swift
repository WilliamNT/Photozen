import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GridCellFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ImageCellView: View {
    let item: ImageItem
    let isSelected: Bool
    let onOpen: () -> Void
    let onSelect: () -> Void

    @State private var thumbnail: NSImage?
    @State private var lastTapTime: Date?
    @State private var isHovered = false
    @EnvironmentObject var model: PhotozenModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(alignment: .bottomTrailing) {
                            if item.isMovieLike {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.5))
                                    .font(.title3)
                                    .padding(4)
                            }
                        }
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1.5)
                } else {
                    PlaceholderView(item: item)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                }

                // Filename overlay on hover
                if isHovered {
                    Text(item.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: GridCellFramesKey.self,
                    value: [item.id: geo.frame(in: .named("viewerSpace"))]
                )
            }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(item.name)
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
        .onTapGesture {
            let now = Date()
            if let last = lastTapTime, now.timeIntervalSince(last) < 0.35 {
                lastTapTime = nil
                onOpen()
            } else {
                lastTapTime = now
                onSelect()
            }
        }
        .contextMenu {
            Button("Open") { onOpen() }
            Button {
                ImageClipboard.copyImage(url: item.url)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            ShareLink(item: item.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button("Get Info") {
                onSelect()
                onOpen()
                model.isInfoOpen = true
            }
            Divider()
            AppPickerMenu(item: item)
            Divider()
            Button("Reveal in Finder") { model.revealInFinder(item) }
        }
        .task(id: item.path) {
            let path = item.path
            let image = await ThumbnailProvider.shared.thumbnail(path: path)
            guard !Task.isCancelled, item.path == path else { return }
            thumbnail = image
        }
    }
}

struct PlaceholderView: View {
    let item: ImageItem

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: iconForType)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(item.url.pathExtension.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(4)
    }

    private var iconForType: String {
        let ext = item.url.pathExtension.lowercased()
        switch ext {
        case "svg": return "doc.richtext"
        case "psd", "xcf": return "paintpalette"
        case "raw", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2": return "camera.aperture"
        case "jxl", "avif", "heif": return "sparkles.rectangle.stack"
        default: return "photo"
        }
    }
}
