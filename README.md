# Photozen

A native macOS SwiftUI app for browsing images across multiple folder locations — including external drives and network shares — with graceful handling of disappearing volumes.

## Features

- **Sidebar directory tree** — add folders and expand/collapse subdirectories
- **Recursive image scanning** — any directory click scans all subfolders for images
- **Broad format support** — JPEG, PNG, TIFF, HEIC, WebP, SVG, RAW (CR2, NEF, ARW, DNG, RAF…), PSD, XCF, and more
- **Placeholder + app picker** — formats SwiftUI can't render get a styled placeholder with a dropdown to open in any installed app
- **Volatile location awareness** — network shares and removable disks are classified automatically and marked "Unavailable" when disconnected
- **Graceful unmount handling** — removing a drive won't crash; the app marks the location and shows a friendly error
- **Search & filter** — filter by name or restrict to Swift-renderable formats
- **Persistence** — added locations survive app restarts

## Building & Running

```bash
# Build and package the .app bundle
./Scripts/build.sh

# Launch the app
./Scripts/run.sh

# Or open in Xcode
open Photozen.xcodeproj
```

The built app is at `build/Photozen.app`.

## Requirements

- macOS 14.0+
- Xcode 15+ (for `xcodebuild`) or the Xcode toolchain (for `swift build`)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) for regenerating the Xcode project after adding files (already installed via Homebrew)

## Architecture

| File | Purpose |
|------|---------|
| `PhotozenApp.swift` | App entry point, menu commands |
| `PhotozenModel.swift` | Central state: locations, scanning, persistence, unmount monitoring |
| `Models.swift` | Data types: `FolderLocation`, `ImageItem`, `LocationKind` |
| `LocationDiscovery.swift` | Classifies folders as built-in / removable / network |
| `ImageScanner.swift` | Recursive file scan + thumbnail rendering |
| `FolderNode.swift` | Lazy sidebar directory tree |
| `ContentView.swift` | NavigationSplitView shell |
| `SidebarView.swift` | Sidebar with locations and expandable subfolders |
| `ImageGridView.swift` | Adaptive image grid + filter bar |
| `ImageCellView.swift` | Thumbnail cell with placeholder fallback |
| `AppPickerMenu.swift` | Dropdown for opening unsupported formats in installed apps |
