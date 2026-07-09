import Foundation
import Observation

/// Watches a folder and auto-sends files dropped into it after launch.
/// ponytail: a directory DispatchSource + a size-stability poll before sending; FSEvents would
/// catch nested changes, but a flat drop folder doesn't need it.
@MainActor
@Observable
final class WatchedFolder {
    static let shared = WatchedFolder()

    private(set) var folderPath: String?
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var seen = Set<String>()
    private var rescan: Task<Void, Never>?

    private init() {
        folderPath = UserDefaults.standard.string(forKey: "watchedFolderPath")
        start()
    }

    func setFolder(_ url: URL?) {
        stop()
        folderPath = url?.path
        UserDefaults.standard.set(folderPath, forKey: "watchedFolderPath")
        start()
    }

    private func start() {
        guard let path = folderPath, FileManager.default.fileExists(atPath: path) else { return }
        seen = currentNames(path) // seed: only files added *after* this point get sent
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { fd = -1; return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        source = src
    }

    private func stop() {
        rescan?.cancel()
        source?.cancel()
        source = nil
    }

    /// Debounce: a burst of write events during a copy collapses into one scan.
    private func scheduleScan() {
        rescan?.cancel()
        rescan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.scan() }
        }
    }

    private func scan() {
        guard let path = folderPath else { return }
        let now = currentNames(path)
        let fresh = now.subtracting(seen)
        seen = now // dropping removed files lets a delete-then-re-add re-send
        for name in fresh {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            Task { await self.sendWhenStable(url) }
        }
    }

    /// Wait until the file stops growing (a cross-volume copy may still be in flight) before sending.
    private func sendWhenStable(_ url: URL) async {
        var last: Int64 = -1
        for _ in 0..<12 {
            guard let size = fileSize(url) else { return } // vanished mid-copy
            if size == last { break }
            last = size
            try? await Task.sleep(for: .milliseconds(600))
        }
        UploadManager.shared.send([url], to: Store.shared.currentAccount)
    }

    private func currentNames(_ path: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return Set(names.filter { name in
            let lower = name.lowercased()
            return !name.hasPrefix(".")                       // dotfiles, .DS_Store
                && !lower.hasSuffix(".download")              // Safari partial
                && !lower.hasSuffix(".crdownload")            // Chrome partial
                && !lower.hasSuffix(".part")                  // generic partial
        })
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
