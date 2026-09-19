import Foundation

@MainActor
final class DirectoryMonitor: ObservableObject {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingEvents: [String: DispatchWorkItem] = [:]
    var onChange: ((String) -> Void)?

    func startMonitoring(path: String) {
        guard sources[path] == nil else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleEvent(for: path)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources[path] = source
    }

    func stopMonitoring(path: String) {
        sources[path]?.cancel()
        sources.removeValue(forKey: path)
        pendingEvents[path]?.cancel()
        pendingEvents.removeValue(forKey: path)
    }

    func stopAll() {
        for path in Array(sources.keys) {
            stopMonitoring(path: path)
        }
    }

    private func handleEvent(for path: String) {
        // Debounce: coalesce rapid file system events within 1 second.
        pendingEvents[path]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange?(path)
            self?.pendingEvents.removeValue(forKey: path)
        }
        pendingEvents[path] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }
}
