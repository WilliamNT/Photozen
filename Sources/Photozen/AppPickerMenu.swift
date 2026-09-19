import AppKit
import SwiftUI

struct AppPickerMenu: View {
    let item: ImageItem
    @State private var apps: [AppInfo] = []

    var body: some View {
        Menu {
            Section("Open with") {
                if apps.isEmpty {
                    Text("Detecting apps…")
                } else {
                    ForEach(apps) { app in
                        Button {
                            openWith(app)
                        } label: {
                            HStack {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                }
                                Text(app.name)
                            }
                        }
                    }
                }

                Divider()

                Button("Choose App…") {
                    chooseApp()
                }
            }
        } label: {
            Label("Open With", systemImage: "arrow.up.forward.app")
        }
        .task(id: item.path) {
            let discovered = await Task.detached(priority: .userInitiated) {
                AppPickerMenu.discoverApps(for: item)
            }.value
            guard !Task.isCancelled else { return }
            apps = discovered
        }
    }

    private func openWith(_ app: AppInfo) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([item.url], withApplicationAt: app.url, configuration: configuration)
    }

    private func chooseApp() {
        Self.chooseApp(for: item.url)
    }

    @MainActor
    static func chooseApp(for itemURL: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([itemURL], withApplicationAt: appURL, configuration: configuration)
    }

    nonisolated static func discoverApps(for item: ImageItem) -> [AppInfo] {
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
        return appURLs.compactMap { appURL in
            let name = FileManager.default.displayName(atPath: appURL.path)
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            return AppInfo(url: appURL, name: name, icon: icon)
        }
    }
}

struct AppInfo: Identifiable {
    let url: URL
    let name: String
    let icon: NSImage?

    var id: String { url.path }
}
