import Foundation

/// Watches Cursor's conversation-search WAL file for write activity and
/// reports it via `onActivity`. Pure trigger: holds an O_EVTONLY fd and
/// never reads file contents, so cost is independent of file size.
///
/// The WAL is absent whenever SQLite last closed cleanly — a normal state,
/// not an error. Task 2 adds the parent-directory fallback for that case;
/// only a missing parent directory (Cursor not installed) leaves the
/// watcher permanently inert.
@MainActor
final class CursorActivityWatcher {
    nonisolated static let defaultWALPath =
        ("~/Library/Application Support/Cursor/User/globalStorage/conversation-search.db-wal"
            as NSString).expandingTildeInPath

    private let filePath: String
    private let directoryPath: String
    private let onActivity: @MainActor () -> Void
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private(set) var isWatching = false

    init(
        filePath: String = CursorActivityWatcher.defaultWALPath,
        onActivity: @escaping @MainActor () -> Void
    ) {
        self.filePath = filePath
        self.directoryPath = (filePath as NSString).deletingLastPathComponent
        self.onActivity = onActivity
    }

    func start() {
        guard !isWatching else { return }
        isWatching = attachToFile()
        if !isWatching {
            Log.info("CursorActivityWatcher inactive: watch target unavailable")
        }
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        isWatching = false
    }

    @discardableResult
    private func attachToFile() -> Bool {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Handlers run on the main queue; hop into MainActor explicitly
            // to keep Swift 6 strict concurrency clean.
            MainActor.assumeIsolated {
                self?.handleFileEvent()
            }
        }
        source.setCancelHandler { close(fd) }
        fileSource = source
        source.resume()
        return true
    }

    private func handleFileEvent() {
        guard let source = fileSource else { return }
        let events = source.data
        if events.contains(.delete) || events.contains(.rename) {
            // SQLite checkpoint replaced the WAL; the old fd is dead.
            fileSource?.cancel()
            fileSource = nil
            isWatching = attachToFile()
            // Task 2 replaces this branch with the directory fallback.
        } else {
            onActivity()
        }
    }
}
