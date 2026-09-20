import SwiftUI

@main
struct PhotozenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PhotozenModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") {
                    model.presentFolderPicker = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Refresh Library") {
                    model.refreshSelected()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.selectedRoot == nil || model.isScanning || model.isRefreshing)

                Button("Force Recreate Cache") {
                    model.forceRecreateCacheSelected()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedRoot == nil || model.isScanning || model.isRefreshing)

                Divider()

                Button(model.selectedRoot != nil ? "Remove \u{201C}\(model.selectedRoot!.name)\u{201D} from Library" : "Remove from Library") {
                    Task { await model.disconnectSelectedRoot() }
                }
                .disabled(model.selectedRoot == nil)
                .keyboardShortcut(.delete, modifiers: [.command])
            }

            CommandGroup(replacing: .printItem) {
                Button("Print…") {
                    model.printCurrentImage()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(!model.canPrint)
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Menu("Find") {
                    Button("Find…") {
                        model.focusSearch()
                    }
                    .keyboardShortcut("f", modifiers: [.command])
                }
            }

            CommandMenu("View") {
                Button(model.isInfoOpen ? "Hide Info" : "Get Info") {
                    model.isInfoOpen.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Divider()

                Button("Zoom In") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.filter.zoomLevel = min(model.filter.zoomLevel + 0.5, 4.0)
                    }
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Zoom Out") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.filter.zoomLevel = max(model.filter.zoomLevel - 0.5, 1.0)
                    }
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Actual Size") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.filter.zoomLevel = 1.0
                    }
                }
                .keyboardShortcut("0", modifiers: [.command])

                Divider()

                Menu("Sort By") {
                    Button(model.filter.sortByDate ? "✓ Date" : "Date") {
                        model.filter.sortByDate = true
                    }
                    Button(!model.filter.sortByDate ? "✓ Name" : "Name") {
                        model.filter.sortByDate = false
                    }
                }

                Divider()

                Button("Enter Full Screen") {
                    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                        window.toggleFullScreen(nil)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.showKeyboardShortcuts.toggle()
                    }
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
