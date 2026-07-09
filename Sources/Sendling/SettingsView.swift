import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "server.rack") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 680, maxWidth: 680, minHeight: 560, idealHeight: 760)
    }
}

// MARK: - Accounts

struct AccountsSettings: View {
    @Environment(Store.self) private var store
    @State private var selectedID: UUID?
    @State private var confirmRemove = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(store.accounts) { account in
                        Label(account.name, systemImage: "externaldrive.connected.to.line.below")
                            .tag(account.id)
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack(spacing: 8) {
                    Button("Add Account", systemImage: "plus") {
                        selectedID = store.addAccount().id
                    }
                    .labelStyle(.iconOnly)

                    Button("Remove Account", systemImage: "minus") {
                        confirmRemove = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(selectedID == nil)

                    Button("Duplicate") {
                        if let account = store.accounts.first(where: { $0.id == selectedID }) {
                            selectedID = store.duplicate(account).id
                        }
                    }
                    .disabled(selectedID == nil)
                    Spacer()
                    if FileChuteImport.isAvailable {
                        Button("Import…") { importFromFileChute() }
                            .help("Import accounts from FileChute (passwords must be re-entered)")
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 160, maxWidth: 220)

            if let id = selectedID, let index = store.accounts.firstIndex(where: { $0.id == id }) {
                AccountDetail(account: bindingFor(index))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Text(store.accounts.isEmpty ? "Add an account to get started." : "Select an account.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selectedID = store.selectedAccountID ?? store.accounts.first?.id }
        .alert("Remove account?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                if let account = store.accounts.first(where: { $0.id == selectedID }) {
                    store.remove(account)
                    selectedID = store.accounts.first?.id
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the account and its sent-file history from Sendling. Files on the server are not touched.")
        }
    }

    private func bindingFor(_ index: Int) -> Binding<Account> {
        Binding(get: { store.accounts[index] },
                set: { store.accounts[index] = $0; store.save() })
    }

    private func importFromFileChute() {
        let existing = Set(store.accounts.map(\.name))
        let imported = FileChuteImport.importAccounts().filter { !existing.contains($0.name) }
        store.accounts.append(contentsOf: imported)
        if store.selectedAccountID == nil { store.selectedAccountID = store.accounts.first?.id }
        store.save()
        if let first = imported.first { selectedID = first.id }
    }
}

struct AccountDetail: View {
    @Environment(Store.self) private var store
    @Binding var account: Account
    @State private var password = ""
    @State private var tab = 0
    /// Download URL as it was before assist overwrote it, so unchecking restores it.
    @State private var preAssistURL: String?
    // Dropbox OAuth flow
    @State private var dropboxPKCE: DropboxAPI.PKCE?
    @State private var dropboxCode = ""
    @State private var dropboxError: String?

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $tab) {
                Text("Server").tag(0)
                Text("Sending").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.top, 10)

            if tab == 0 { serverForm } else { sendingForm }
        }
        .onAppear { password = store.password(for: account) }
        .onChange(of: account.id) { _, _ in
            password = store.password(for: account)
            preAssistURL = nil
        }
    }

    private var serverForm: some View {
        Form {
            Section {
                TextField("Description:", text: $account.name)
                Picker("Type:", selection: $account.type) {
                    ForEach(AccountType.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            if account.type == .dropbox {
                dropboxSection
            } else {
                connectionSection
                if !account.type.linksFromAPI {
                    urlSection
                } else {
                    Section {
                        LabeledContent("Share links:") {
                            Text("Created through the Nextcloud sharing API after each upload")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                TestConnectionRow(account: account, password: password)
            }
        }
        .formStyle(.grouped)
        .onChange(of: account.host) { _, _ in syncAssistedURL() }
        .onChange(of: account.remoteDir) { _, _ in syncAssistedURL() }
    }

    private var isServerURLType: Bool { account.type == .webdav || account.type == .nextcloud }

    private var connectionSection: some View {
        Section {
            TextField(isServerURLType ? "Server URL:" : "Host name:",
                      text: $account.host,
                      prompt: Text(account.type == .nextcloud ? "https://cloud.example.com"
                                   : isServerURLType ? "https://dav.example.com" : "ftp.example.com"))

            if !isServerURLType {
                TextField("Port:", value: $account.port,
                          format: .number.grouping(.never),
                          prompt: Text("\(account.type.defaultPort)"))
                    .multilineTextAlignment(.trailing)
            }

            TextField("User name:", text: $account.username)
            SecureField(account.type == .nextcloud ? "App password:" : "Password:", text: $password)
                .onChange(of: password) { _, new in store.setPassword(new, for: account) }

            TextField(account.type == .nextcloud ? "Folder:" : "Remote directory:",
                      text: $account.remoteDir,
                      prompt: Text(account.type == .nextcloud ? "Sendling" : "public_html/files"))
        } footer: {
            Text(connectionFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionFooter: String {
        switch account.type {
        case .sftp:
            "Directory is relative to the login root and created if missing. Leave the password empty to use your SSH keys."
        case .nextcloud:
            "Create an app password under Nextcloud → Personal settings → Security. The folder lives in your Files and is created automatically."
        default:
            "Directory is relative to the login root and created if missing."
        }
    }

    private var urlSection: some View {
        Section {
            LabeledContent("Upload URL:") {
                Text(account.host.isEmpty ? "—" : account.uploadURLPreview)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Toggle("Help me fill in the URL below", isOn: urlAssistBinding)

            TextField("Download URL:", text: $account.downloadURLBase,
                      prompt: Text("https://example.com/files"))
                .disabled(account.urlAssist ?? false)
                .foregroundStyle((account.urlAssist ?? false) ? .secondary : .primary)
        } footer: {
            Text("The public web address where uploads appear. The suggestion reflects a typical setup but may not be exactly correct for yours — turn assist off to edit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dropboxSection: some View {
        Section {
            TextField("App key:", text: $account.dropboxAppKeyValue)

            LabeledContent("Status:") {
                Label(password.isEmpty ? "Not connected" : "Connected",
                      systemImage: password.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                    .foregroundStyle(password.isEmpty ? Color.secondary : Color.green)
            }

            if dropboxPKCE == nil {
                Button(password.isEmpty ? "Connect to Dropbox…" : "Reconnect…") {
                    let pkce = DropboxAPI.makePKCE()
                    dropboxPKCE = pkce
                    dropboxError = nil
                    NSWorkspace.shared.open(DropboxAPI.authorizeURL(
                        appKey: account.dropboxAppKey ?? "", challenge: pkce.challenge))
                }
                .disabled((account.dropboxAppKey ?? "").isEmpty)
            } else {
                TextField("Paste the code from the browser:", text: $dropboxCode)
                HStack {
                    Button("Finish Connecting") { finishDropboxAuth() }
                        .disabled(dropboxCode.isEmpty)
                    Button("Cancel") {
                        dropboxPKCE = nil
                        dropboxCode = ""
                    }
                }
            }

            if let dropboxError {
                Text(dropboxError).font(.caption).foregroundStyle(.red)
            }

            TextField("Dropbox folder:", text: $account.remoteDir, prompt: Text("Sendling"))
        } footer: {
            Text("One-time setup: create a free app at dropbox.com/developers/apps (scoped access, full Dropbox) with permissions files.content.write, files.content.read, sharing.write, sharing.read. Paste its App key above, then Connect. Share links are created automatically after each upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func finishDropboxAuth() {
        guard let pkce = dropboxPKCE else { return }
        let appKey = account.dropboxAppKey ?? ""
        let code = dropboxCode
        Task {
            do {
                let refreshToken = try await DropboxAPI.exchangeCode(code, appKey: appKey, verifier: pkce.verifier)
                store.setPassword(refreshToken, for: account)
                password = refreshToken
                dropboxPKCE = nil
                dropboxCode = ""
                dropboxError = nil
            } catch {
                dropboxError = error.localizedDescription
            }
        }
    }

    private var urlAssistBinding: Binding<Bool> {
        Binding(get: { account.urlAssist ?? false },
                set: { on in
                    account.urlAssist = on
                    if on {
                        preAssistURL = account.downloadURLBase
                        account.downloadURLBase = account.suggestedDownloadURL
                    } else if let previous = preAssistURL {
                        account.downloadURLBase = previous
                        preAssistURL = nil
                    }
                })
    }

    private func syncAssistedURL() {
        if account.urlAssist == true {
            account.downloadURLBase = account.suggestedDownloadURL
        }
    }

    private var sendingForm: some View {
        Form {
            Section {
                Picker("Files expire after:", selection: $account.expireDays) {
                    Text("Never").tag(0)
                    ForEach([1, 3, 7, 14, 30, 60, 90, 180, 365], id: \.self) {
                        Text("\($0) days").tag($0)
                    }
                }

                Picker("Connection timeout:", selection: $account.timeoutSeconds) {
                    ForEach([15, 30, 60, 120, 300], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }

            if account.type.linksFromAPI {
                Section {
                    Picker("Link expires after:", selection: $account.linkExpireDaysValue) {
                        Text("Never").tag(0)
                        ForEach([1, 3, 7, 14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }
                } header: {
                    Text("Share links")
                } footer: {
                    Text(account.type == .dropbox
                         ? "Applied to each new share link. Dropbox requires a Professional or Business plan for link expiry."
                         : "Applied to each new share link created after upload.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Default archive type:", selection: $account.archiveType) {
                    ForEach(ArchiveType.allCases) { Text($0.label).tag($0) }
                }

                Toggle("Exclude .DS_Store files", isOn: $account.excludeDSStore)

                SecureField("Default archive password:", text: $account.archivePassword)

                Picker("Archive name based on:", selection: $account.archiveNaming) {
                    ForEach(ArchiveNaming.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("A random string makes file names on your server harder to guess.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("When sending a file:", selection: $account.fileWrapPolicy) {
                    Text("Always wrap in an archive").tag(WrapPolicy.always)
                    Text("Never wrap (send as-is)").tag(WrapPolicy.never)
                    Text("Ask me").tag(WrapPolicy.ask)
                }

                if account.fileWrapPolicy == .always {
                    TextField("Never wrap these extensions:", text: $account.neverWrapExtensions)
                }

                Picker("When sending a folder:", selection: $account.folderWrapPolicy) {
                    Text("Wrap with default name").tag(WrapPolicy.always)
                    Text("Ask me").tag(WrapPolicy.ask)
                }
            } footer: {
                Text("When sending multiple files or folders, Sendling always asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Test Connection" button with an inline ✓/✗ result.
struct TestConnectionRow: View {
    let account: Account
    let password: String
    @State private var testing = false
    @State private var result: String? // nil = untested, "" = ok, else error message

    var body: some View {
        HStack(spacing: 8) {
            Button("Test Connection", action: runTest)
                .disabled(testing)
            if testing {
                ProgressView().controlSize(.small)
            } else if let result {
                if result.isEmpty {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(result, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
    }

    private func runTest() {
        testing = true
        result = nil
        Task {
            result = await Transfer.test(account: account, password: password) ?? ""
            testing = false
        }
    }
}

/// "Watched folder" — files dropped into it upload automatically to the current account.
struct WatchedFolderSection: View {
    @State private var watched = WatchedFolder.shared

    var body: some View {
        Section {
            if let path = watched.folderPath {
                LabeledContent("Watching:") {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Change…", action: chooseFolder)
                    Button("Stop Watching") { watched.setFolder(nil) }
                    Spacer()
                }
            } else {
                Button("Choose Folder…", action: chooseFolder)
            }
        } header: {
            Text("Watched folder")
        } footer: {
            Text("Files added to this folder upload automatically to the current account. Existing files are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to watch — new files in it upload automatically"
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            watched.setFolder(url)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @AppStorage("autoCopyLink") private var autoCopyLink = true
    @AppStorage("showNotification") private var showNotification = true
    @AppStorage("completionSound") private var completionSound = "None"
    @AppStorage("autoDeleteExpired") private var autoDeleteExpired = false
    @AppStorage("scanAtLaunch") private var scanAtLaunch = true
    @AppStorage("checkUpdatesAtLaunch") private var checkUpdatesAtLaunch = true
    @AppStorage("optimizeImages") private var optimizeImages = false
    @AppStorage("optimizeImagesMaxDim") private var optimizeMaxDim = 2048
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var iCloudSync = Store.shared.iCloudSyncEnabled

    // Filesystem scan once, not per render
    private static let soundNames: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds"))?
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted() ?? []
        return ["None"] + names
    }()

    var body: some View {
        Form {
            Section("On upload completion") {
                Toggle("Copy download link to clipboard", isOn: $autoCopyLink)
                Toggle("Show floating notification", isOn: $showNotification)
                Picker("Play sound:", selection: $completionSound) {
                    ForEach(Self.soundNames, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: completionSound) { _, new in
                    if new != "None" { NSSound(named: new)?.play() }
                }
            }

            Section {
                Toggle("Optimize images before upload", isOn: $optimizeImages)
                if optimizeImages {
                    Picker("Max image size:", selection: $optimizeMaxDim) {
                        Text("1024 px").tag(1024)
                        Text("2048 px").tag(2048)
                        Text("4096 px").tag(4096)
                    }
                }
            } header: {
                Text("Uploads")
            } footer: {
                Text("Large JPEG/PNG/HEIC images are downscaled and recompressed before upload. The original on disk is untouched, and the optimized copy is only used when it's actually smaller.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Housekeeping") {
                Toggle("Scan server at launch", isOn: $scanAtLaunch)
                Toggle("Delete expired files from server at launch", isOn: $autoDeleteExpired)
                Text("Expiry is configured per account, under Accounts → Sending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WatchedFolderSection()

            Section {
                Toggle("Sync accounts across my Macs", isOn: $iCloudSync)
                    .disabled(!store.iCloudAvailable)
                    .onChange(of: iCloudSync) { _, on in store.setiCloudSync(on) }
            } header: {
                Text("iCloud")
            } footer: {
                Text(store.iCloudAvailable
                     ? "Accounts and sent-file history sync through iCloud Drive. Passwords stay on each Mac for security — enter each account’s password once per Mac."
                     : "Turn on iCloud Drive in System Settings to sync across your Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Toggle("Show Sendling in the menu bar", isOn: $showMenuBarIcon)
            }

            Section {
                LabeledContent("Version", value: Sendling.version)
                Toggle("Check for updates at launch", isOn: $checkUpdatesAtLaunch)
                HStack {
                    Link("Sendling on GitHub", destination: Sendling.projectURL)
                    Spacer()
                    Button("Check Now") {
                        Task { await UpdateChecker.shared.check() }
                        NSWorkspace.shared.open(Sendling.releasesURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
