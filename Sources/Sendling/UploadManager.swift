import AppKit
import Observation
import SwiftUI

// MARK: - Job model

struct UploadJob: Identifiable {
    enum Status: Equatable {
        case waiting, archiving, uploading, done
        case failed(String)
    }

    let id = UUID()
    let batchID: UUID
    var displayName: String
    var status: Status = .waiting
    /// nil while indeterminate (SFTP, archiving)
    var progress: Double?

    var isActive: Bool {
        switch status {
        case .waiting, .archiving, .uploading: true
        case .done, .failed: false
        }
    }
}

/// One unit of work: either a raw file (optionally renamed / image-compressed) or a built archive.
enum SendItem {
    case raw(URL, remoteName: String? = nil, imageOpt: ImageOptSetting? = nil)
    case archive(sources: [URL], name: String, type: ArchiveType, password: String)

    var displayName: String {
        switch self {
        case .raw(let url, let remoteName, _): remoteName ?? url.lastPathComponent
        case .archive(_, let name, let type, _): "\(name).\(type.fileExtension)"
        }
    }
}

/// Presented as a sheet when the account's wrap policy says "ask", or on ⌥-drop for full options.
struct AskRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let account: Account
    var suggestedName: String
    var archiveType: ArchiveType
    var archivePassword: String
    /// Single plain file may be sent as-is; folders/multiples can be sent individually.
    var canSendAsIs: Bool
    /// ⌥-drop: also show rename + per-send image-compression + link-protection fields.
    var showsOptions: Bool = false
    var renameTo: String = ""       // remote filename for a single raw file
    var compressImage: Bool = false // per-send image optimization
    var imageMaxDim: Int = 2048
    var linkExpireDays: Int = 0     // per-send override of the account's link expiry

    var hasImage: Bool { urls.contains { ImageOptimizer.isImage($0) } }
}

// MARK: - Upload manager

@MainActor
@Observable
final class UploadManager {
    static let shared = UploadManager()

    var jobs: [UploadJob] = []
    var askRequest: AskRequest?
    var lastError: String?

    /// Binding surface for the error alert.
    var hasError: Bool {
        get { lastError != nil }
        set { if !newValue { lastError = nil } }
    }

    // @AppStorage doesn't publish inside @Observable — plain UserDefaults reads;
    // GeneralSettings owns the toggles with its own @AppStorage.
    var autoCopyLink: Bool { UserDefaults.standard.object(forKey: "autoCopyLink") == nil
        || UserDefaults.standard.bool(forKey: "autoCopyLink") }
    var showNotification: Bool { UserDefaults.standard.object(forKey: "showNotification") == nil
        || UserDefaults.standard.bool(forKey: "showNotification") }
    var completionSound: String { UserDefaults.standard.string(forKey: "completionSound") ?? "None" }

    private let store = Store.shared
    private var runner: ProcessRunner?
    private var queue: [(SendItem, Account, UUID)] = []
    private var working = false
    private var batchLinks: [UUID: [URL]] = [:]
    private var pendingAsks: [AskRequest] = []
    private var retryable: [UUID: (SendItem, Account)] = [:] // failed job → what to resend

    var activeJobs: [UploadJob] { jobs.filter(\.isActive) }
    var isCompressing: Bool { jobs.contains { $0.status == .archiving } }
    var overallProgress: Double? {
        let active = activeJobs
        guard !active.isEmpty else { return nil }
        let known = active.compactMap(\.progress)
        return known.isEmpty ? nil : known.reduce(0, +) / Double(active.count)
    }

    // MARK: Entry point — decide how to send

    /// `forceArchive` — always wrap the drop into one archive (the "Compress & send" well),
    /// bypassing the account's wrap policy and the ask sheet.
    func send(_ urls: [URL], to account: Account?, forceArchive: Bool = false, forceOptions: Bool = false) {
        guard let account else {
            lastError = "Add an account in Settings before sending files."
            return
        }
        guard !urls.isEmpty else { return }

        if forceOptions {
            ask(urls: urls, account: account, canSendAsIs: true, showsOptions: true)
            return
        }
        if forceArchive {
            enqueueArchive(urls, account: account)
            return
        }

        let isDir: (URL) -> Bool = {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }

        if urls.count == 1, let url = urls.first {
            if isDir(url) {
                // Folders are always archived; policy decides whether to ask first
                if account.folderWrapPolicy == .ask {
                    ask(urls: urls, account: account, canSendAsIs: false)
                } else {
                    enqueueArchive(urls, account: account)
                }
            } else {
                let ext = url.pathExtension.lowercased()
                switch account.fileWrapPolicy {
                case .never:
                    enqueue([.raw(url)], account: account)
                case .always:
                    account.neverWrapExtensionSet.contains(ext)
                        ? enqueue([.raw(url)], account: account)
                        : enqueueArchive(urls, account: account)
                case .ask:
                    ask(urls: urls, account: account, canSendAsIs: true)
                }
            }
        } else {
            // Multiple items: always ask (one archive vs. individually)
            ask(urls: urls, account: account, canSendAsIs: true)
        }
    }

    private func ask(urls: [URL], account: Account, canSendAsIs: Bool, showsOptions: Bool = false) {
        let request = AskRequest(urls: urls,
                                 account: account,
                                 suggestedName: Archiver.archiveName(for: urls, account: account),
                                 archiveType: account.archiveType,
                                 archivePassword: account.archivePassword,
                                 canSendAsIs: canSendAsIs,
                                 showsOptions: showsOptions,
                                 renameTo: urls.count == 1 ? urls[0].lastPathComponent : "",
                                 compressImage: ImageOptimizer.isEnabled,
                                 imageMaxDim: ImageOptimizer.maxDimension,
                                 linkExpireDays: account.linkExpireDays ?? 0)
        // Queue behind an open sheet instead of silently replacing (and dropping) it.
        if askRequest == nil { askRequest = request } else { pendingAsks.append(request) }
    }

    /// Presents the next queued ask, or dismisses the sheet.
    private func advanceAsk() {
        askRequest = pendingAsks.isEmpty ? nil : pendingAsks.removeFirst()
    }

    /// Called when the ask sheet is cancelled.
    func cancelAsk() {
        advanceAsk()
    }

    /// Called by the ask sheet.
    func resolveAsk(_ request: AskRequest, wrap: Bool) {
        advanceAsk()
        // Apply the per-send link-expiry override onto a copy (same id → same Keychain password).
        var account = request.account
        if request.showsOptions {
            account.linkExpireDays = request.linkExpireDays == 0 ? nil : request.linkExpireDays
        }
        if wrap {
            enqueue([.archive(sources: request.urls, name: request.suggestedName,
                              type: request.archiveType, password: request.archivePassword)],
                    account: account)
        } else {
            // Send individually: plain files raw, folders auto-archived
            let isDir: (URL) -> Bool = {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            }
            let items: [SendItem] = request.urls.map { url in
                if isDir(url) {
                    return .archive(sources: [url],
                                    name: Archiver.archiveName(for: [url], account: account),
                                    type: account.archiveType,
                                    password: account.archivePassword)
                }
                // Rename only a single raw file, and only when the user changed it.
                let rename = request.showsOptions && request.urls.count == 1
                    && !request.renameTo.isEmpty && request.renameTo != url.lastPathComponent
                    ? request.renameTo : nil
                // Per-send image compression override, only for image files.
                let imageOpt = request.showsOptions && ImageOptimizer.isImage(url)
                    ? ImageOptSetting(enabled: request.compressImage, maxDim: request.imageMaxDim) : nil
                return .raw(url, remoteName: rename, imageOpt: imageOpt)
            }
            enqueue(items, account: account)
        }
    }

    private func enqueueArchive(_ urls: [URL], account: Account) {
        enqueue([.archive(sources: urls,
                          name: Archiver.archiveName(for: urls, account: account),
                          type: account.archiveType,
                          password: account.archivePassword)],
                account: account)
    }

    // MARK: Queue

    private func enqueue(_ items: [SendItem], account: Account) {
        let batchID = UUID()
        batchLinks[batchID] = []
        for item in items {
            jobs.append(UploadJob(batchID: batchID, displayName: item.displayName))
            queue.append((item, account, batchID))
        }
        pump()
    }

    private func pump() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let (item, account, batchID) = queue.removeFirst()
        let jobID = jobs.first(where: { $0.batchID == batchID && $0.status == .waiting })?.id

        Task {
            await run(item: item, account: account, batchID: batchID, jobID: jobID)
            working = false
            if !queue.contains(where: { $0.2 == batchID }) { finishBatch(batchID) }
            pump()
        }
    }

    /// Core upload for one item: optimize/archive as needed, upload, fetch a share link, record
    /// history. Returns the download/share URL. `setJob` no-ops when jobID is nil (Shortcuts path).
    private func deliver(_ item: SendItem, account: Account, runner: ProcessRunner,
                         jobID: UUID?) async throws -> URL? {
        let password = store.password(for: account)
        var tempDir: URL?
        defer { if let tempDir { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) } }

        let localURL: URL
        let name: String
        var imageOptOverride: ImageOptSetting?
        switch item {
        case .raw(let url, let remoteName, let opt):
            localURL = url
            name = remoteName ?? url.lastPathComponent
            imageOptOverride = opt
        case .archive(let sources, let archiveName, let type, let archivePW):
            setJob(jobID, status: .archiving, progress: nil)
            let archiveURL = try await Archiver.archive(
                sources: sources, name: archiveName, type: type, password: archivePW,
                excludeDSStore: account.excludeDSStore, runner: runner)
            localURL = archiveURL
            tempDir = archiveURL
            name = archiveURL.lastPathComponent
        }

        // Optionally shrink a large image before upload (per-send override or global setting).
        // The optimized temp keeps the same filename, so the remote name is unchanged.
        let optimized = await ImageOptimizer.optimizedIfNeeded(localURL, override: imageOptOverride)
        let uploadURL = optimized ?? localURL
        if let optimized, tempDir == nil { tempDir = optimized } // clean up the opt temp too

        setJob(jobID, status: .uploading, progress: account.type == .sftp ? nil : 0)
        try await Transfer.upload(uploadURL, as: name, to: account, password: password,
                                  runner: runner) { [weak self] pct in
            Task { @MainActor in self?.setJob(jobID, status: .uploading, progress: pct) }
        }

        let size = (try? uploadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var file = SentFile(accountID: account.id, name: name, size: size, sentDate: .now)
        if account.type.linksFromAPI {
            file.link = try? await Transfer.shareLink(for: name, account: account, password: password)
        }
        store.add(file)
        return account.downloadURL(for: file)
    }

    /// Turns dropped URLs into send items without the ask UI (used by the Shortcuts action).
    private func sendItems(for urls: [URL], account: Account, forceArchive: Bool) -> [SendItem] {
        let isDir: (URL) -> Bool = {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        if forceArchive {
            return [.archive(sources: urls, name: Archiver.archiveName(for: urls, account: account),
                             type: account.archiveType, password: account.archivePassword)]
        }
        return urls.map { url in
            isDir(url)
                ? .archive(sources: [url], name: Archiver.archiveName(for: [url], account: account),
                           type: account.archiveType, password: account.archivePassword)
                : .raw(url)
        }
    }

    /// Automation hook: `sendling://send?path=/abs/file&compress=1` (repeat `path` for multiple).
    /// Callable from Shortcuts' "Open URL", Automator, or `open`.
    func handleSchemeURL(_ url: URL) {
        guard url.scheme == "sendling", url.host == "send",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = comps.queryItems ?? []
        let paths = items.filter { $0.name == "path" }.compactMap(\.value)
        let compress = items.first { $0.name == "compress" }?.value == "1"
        let fileURLs = paths.map { URL(fileURLWithPath: $0) }
        if !fileURLs.isEmpty { send(fileURLs, to: store.currentAccount, forceArchive: compress) }
    }

    /// Upload for the Shortcuts action — no queue/toast; returns the resulting link string(s).
    func uploadForShortcut(_ urls: [URL], compress: Bool) async throws -> [String] {
        guard let account = store.currentAccount else {
            throw TransferError(message: "No account is configured in Sendling.")
        }
        let runner = ProcessRunner()
        var links: [String] = []
        for item in sendItems(for: urls, account: account, forceArchive: compress) {
            if let url = try await deliver(item, account: account, runner: runner, jobID: nil) {
                links.append(url.absoluteString)
            }
        }
        return links
    }

    private func run(item: SendItem, account: Account, batchID: UUID, jobID: UUID?) async {
        let runner = ProcessRunner()
        self.runner = runner
        do {
            let url = try await deliver(item, account: account, runner: runner, jobID: jobID)
            if let url { batchLinks[batchID, default: []].append(url) }
            setJob(jobID, status: .done, progress: 1)
            if showNotification {
                // The clipboard is only written in finishBatch (whole batch's links), so claim
                // "copied" only on the last file of the batch — earlier toasts just show the URL.
                let isLast = !queue.contains(where: { $0.2 == batchID })
                    && !jobs.contains(where: { $0.batchID == batchID && $0.id != jobID && $0.isActive })
                Toast.show(fileName: item.displayName, url: url, copied: autoCopyLink && url != nil && isLast)
            }
        } catch is CancellationError {
            removeJob(jobID)
        } catch {
            setJob(jobID, status: .failed(error.localizedDescription), progress: nil)
            if let jobID { retryable[jobID] = (item, account) } // keep it so the user can retry
            if showNotification {
                Toast.show(fileName: item.displayName, url: nil,
                           error: error.localizedDescription, copied: false)
            }
        }
    }

    private func finishBatch(_ batchID: UUID) {
        let links = batchLinks.removeValue(forKey: batchID) ?? []
        // Fire completion side effects only if a job in this batch actually succeeded. A fully
        // cancelled batch (jobs removed on CancellationError) must not copy/sound; a successful
        // one with no download URL (SFTP before a base URL is set) still should sound + clean up.
        guard jobs.contains(where: { $0.batchID == batchID && $0.status == .done }) else { return }

        if autoCopyLink, !links.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        }
        if completionSound != "None" { NSSound(named: completionSound)?.play() }

        // Clear finished jobs after a beat so the UI can show 100%
        Task {
            try? await Task.sleep(for: .seconds(2))
            jobs.removeAll { !$0.isActive && $0.batchID == batchID && $0.status == .done }
        }
    }

    // MARK: Actions

    func cancelAll() {
        queue.removeAll()
        runner?.cancel()
        jobs.removeAll(where: \.isActive)
        batchLinks.removeAll() // never-started batches would otherwise leak their entries
    }

    func dismissJob(_ id: UploadJob.ID) {
        jobs.removeAll { $0.id == id }
        retryable[id] = nil
    }

    var canRetry: (UploadJob.ID) -> Bool { { self.retryable[$0] != nil } }

    /// Re-send a failed job.
    func retry(_ id: UploadJob.ID) {
        guard let (item, account) = retryable.removeValue(forKey: id) else { return }
        jobs.removeAll { $0.id == id }
        enqueue([item], account: account)
    }

    private func setJob(_ id: UUID?, status: UploadJob.Status, progress: Double?) {
        guard let id, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        // A late progress callback (stderr handler races the termination handler) must not
        // resurrect a finished job back to .uploading — it would stay "active" forever.
        if case .uploading = status, !jobs[i].isActive { return }
        jobs[i].status = status
        jobs[i].progress = progress
    }

    private func removeJob(_ id: UUID?) {
        guard let id else { return }
        jobs.removeAll { $0.id == id }
    }

    // MARK: Remote delete / refresh

    func deleteRemote(ids: Set<SentFile.ID>) async -> [String] {
        var errors: [String] = []
        for id in ids {
            guard let file = store.files.first(where: { $0.id == id }),
                  let account = store.accounts.first(where: { $0.id == file.accountID }) else { continue }
            do {
                try await Transfer.delete(fileName: file.name, from: account,
                                          password: store.password(for: account))
                store.removeFiles(ids: [id])
            } catch {
                if file.missing {
                    store.removeFiles(ids: [id]) // already gone remotely
                } else {
                    errors.append("\(file.name): \(error.localizedDescription)")
                }
            }
        }
        return errors
    }

    func deleteExpired() async -> [String] {
        await deleteRemote(ids: Set(store.expiredFiles.map(\.id)))
    }

    func refresh(quiet: Bool = false) async {
        guard let account = store.currentAccount else { return }

        if account.type == .webdav {
            // No listing for WebDAV — verify known files via HEAD instead
            let checks = store.currentFiles
            var results: [Bool?] = []
            await withTaskGroup(of: (SentFile.ID, Bool?).self) { group in
                for file in checks {
                    group.addTask { (file.id, await Transfer.exists(file, account: account)) }
                }
                for await (id, exists) in group {
                    results.append(exists)
                    if let exists { store.markMissing(id, missing: !exists) }
                }
            }
            // Nothing verified (server unreachable) — don't let a manual refresh look successful.
            if !quiet, !checks.isEmpty, results.allSatisfy({ $0 == nil }) {
                lastError = "Refresh failed: the server couldn’t be reached."
            }
            return
        }

        do {
            let entries = try await Transfer.list(account: account, password: store.password(for: account))
            store.reconcile(accountID: account.id, remote: entries)
            if account.type.linksFromAPI {
                await fillShareLinks(account: account)
            }
        } catch {
            if !quiet { lastError = "Refresh failed: \(error.localizedDescription)" }
        }
    }

    /// Dropbox/Nextcloud links come from the API per file, not from a base URL.
    /// ponytail: sequential fetch; fine for a sending folder, slow for thousands of files.
    private func fillShareLinks(account: Account) async {
        let password = store.password(for: account)
        for file in store.currentFiles where file.link == nil && !file.missing && file.accountID == account.id {
            if let link = try? await Transfer.shareLink(for: file.name, account: account, password: password) {
                store.setLink(file.id, link)
            }
        }
    }
}
