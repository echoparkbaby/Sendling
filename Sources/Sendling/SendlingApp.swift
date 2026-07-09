import SwiftUI
import AppKit

@main
struct SendlingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = Store.shared
    @State private var uploads = UploadManager.shared
    @State private var watched = WatchedFolder.shared // instantiate → starts watching if configured
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window("Sendling", id: "main") {
            ContentView()
                .environment(store)
                .environment(uploads)
        }
        .defaultSize(width: 720, height: 460)
        .commands { commands }

        Settings {
            SettingsView()
                .environment(store)
                .environment(uploads)
        }

        MenuBarExtra("Sendling", systemImage: "paperplane.circle.fill", isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environment(store)
                .environment(uploads)
        }
    }

    // MARK: Menus

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Send Files…") { openPanel(uploads: uploads, store: store) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.accounts.isEmpty)
        }

        CommandMenu("Links") {
            Button("Copy Link") { linkAction { copy($0) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Button("Copy as Markdown") { copyFormatted(markdown: true) }
                .disabled(store.selection.isEmpty)
            Button("Copy as HTML") { copyFormatted(markdown: false) }
                .disabled(store.selection.isEmpty)
            Button("Open in Browser") { linkAction { $0.forEach { NSWorkspace.shared.open($0) } } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Button("Compose Email") { linkAction { composeEmail(urls: $0) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Delete Expired Files") {
                Task {
                    let errors = await uploads.deleteExpired()
                    if !errors.isEmpty {
                        uploads.lastError = "Some expired files couldn’t be deleted:\n"
                            + errors.joined(separator: "\n")
                    }
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(store.expiredFiles.isEmpty)
        }

        CommandMenu("Account") {
            ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.name) {
                    store.selectedAccountID = account.id
                    store.save()
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Visit Our Website") { NSWorkspace.shared.open(Sendling.projectURL) }
            Button("Check for Updates…") { NSWorkspace.shared.open(Sendling.releasesURL) }
        }
    }

    private func linkAction(_ action: ([URL]) -> Void) {
        guard let account = store.currentAccount else { return }
        let urls = store.currentFiles
            .filter { store.selection.contains($0.id) }
            .compactMap { account.downloadURL(for: $0) }
        if !urls.isEmpty { action(urls) }
    }

    private func copy(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
    }

    private func copyFormatted(markdown: Bool) {
        guard let account = store.currentAccount else { return }
        let pairs = store.currentFiles
            .filter { store.selection.contains($0.id) }
            .compactMap { file in account.downloadURL(for: file).map { (file.name, $0.absoluteString) } }
        guard !pairs.isEmpty else { return }
        let text = pairs.map { name, url in
            markdown ? "[\(name)](\(url))" : "<a href=\"\(url)\">\(htmlEscape(name))</a>"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Menu bar extra

struct MenuBarContent: View {
    @Environment(Store.self) private var store
    @Environment(UploadManager.self) private var uploads
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !uploads.activeJobs.isEmpty {
                Text("Uploading \(uploads.activeJobs.count) item\(uploads.activeJobs.count == 1 ? "" : "s")…")
                Divider()
            }

            Button("Send Files…") {
                NSApp.activate(ignoringOtherApps: true)
                openPanel(uploads: uploads, store: store)
            }
            .disabled(store.accounts.isEmpty)

            Button("Open Sendling") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Divider()

            let recent = Array(store.currentFiles.sorted { $0.sentDate > $1.sentDate }.prefix(5))
            if !recent.isEmpty, let account = store.currentAccount {
                Text("Recent — click to copy link")
                ForEach(recent) { file in
                    Button(file.name) {
                        if let url = account.downloadURL(for: file) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
                Divider()
            }

            Button("Quit Sendling") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - App delegate (dock drops, launch housekeeping)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            UploadManager.shared.send(urls, to: Store.shared.currentAccount)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self // enables the Finder "Send with Sendling" Services items

        let defaults = UserDefaults.standard
        let deleteExpired = defaults.bool(forKey: "autoDeleteExpired")
        // default true when the key has never been set
        let scan = defaults.object(forKey: "scanAtLaunch") == nil || defaults.bool(forKey: "scanAtLaunch")
        // One sequential task: refresh must not run mid-delete or its LIST could re-import a
        // file that deleteExpired just removed, resurrecting it in history.
        Task { @MainActor in
            if deleteExpired { _ = await UploadManager.shared.deleteExpired() }
            if scan { await UploadManager.shared.refresh(quiet: true) }
        }
        // default true when the key has never been set
        if defaults.object(forKey: "checkUpdatesAtLaunch") == nil || defaults.bool(forKey: "checkUpdatesAtLaunch") {
            Task { @MainActor in await UpdateChecker.shared.check() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: Finder Services ("Send with Sendling")

    @objc func sendFiles(_ pboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString>) {
        serviceSend(pboard, compress: false)
    }

    @objc func compressAndSendFiles(_ pboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString>) {
        serviceSend(pboard, compress: true)
    }

    private func serviceSend(_ pboard: NSPasteboard, compress: Bool) {
        let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            UploadManager.shared.send(urls, to: Store.shared.currentAccount, forceArchive: compress)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Pick up account/history changes another Mac synced via iCloud while we were away.
        Task { @MainActor in Store.shared.reload() }
    }
}
