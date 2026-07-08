import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(UploadManager.self) private var uploads

    @State private var sortOrder = [KeyPathComparator(\SentFile.sentDate, order: .reverse)]
    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State private var confirmDelete = false
    @State private var pendingDeleteIDs: Set<SentFile.ID> = []
    @State private var deleteErrors: [String] = []
    @State private var showDeleteErrors = false
    @State private var refreshing = false

    private var visibleFiles: [SentFile] {
        var files = store.currentFiles
        if !searchText.isEmpty {
            files = files.filter { $0.name.localizedStandardContains(searchText) }
        }
        return files.sorted(using: sortOrder)
    }

    private var selectedFiles: [SentFile] {
        visibleFiles.filter { store.selection.contains($0.id) }
    }

    var body: some View {
        @Bindable var uploads = uploads

        VStack(spacing: 0) {
            if !store.accounts.isEmpty {
                HeaderBar(files: selectedFiles, account: store.currentAccount)
                Divider()
            }

            if store.accounts.isEmpty {
                ContentUnavailableView {
                    Label("Welcome to Sendling", systemImage: "server.rack")
                } description: {
                    Text("Add a server account to start sending files.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                        .buttonStyle(.borderedProminent)
                }
            } else if store.currentFiles.isEmpty {
                ContentUnavailableView {
                    Label("Drop files to send", systemImage: "paperplane")
                } description: {
                    Text("Files you drop here upload to “\(store.currentAccount?.name ?? "")” and the download link lands on your clipboard. Click ⟳ below to load what’s already on the server.")
                } actions: {
                    Button("Choose Files…") { openPanel(uploads: uploads, store: store) }
                }
            } else {
                fileTable
            }

            Divider()
            BottomBar(refreshing: $refreshing, itemCount: visibleFiles.count, refresh: refresh)
        }
        .frame(minWidth: 620, minHeight: 380)
        .overlay { if isDropTargeted { DropOverlay(accountName: store.currentAccount?.name) } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers, uploads: uploads, store: store)
        }
        .sheet(item: $uploads.askRequest) { AskSheet(request: $0) }
        .alert("Delete from server?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes ^[\(pendingDeleteIDs.count) file](inflect: true) from the server. Links will stop working.")
        }
        .alert("Couldn’t delete some files", isPresented: $showDeleteErrors) {
            Button("OK") { deleteErrors = [] }
        } message: {
            Text(deleteErrors.joined(separator: "\n"))
        }
        .alert("Sendling", isPresented: $uploads.hasError) {
            Button("OK") { uploads.lastError = nil }
        } message: {
            Text(uploads.lastError ?? "")
        }
        .onDeleteCommand {
            // Scope to visible rows of the current account, not the raw (possibly stale) selection
            let ids = Set(selectedFiles.map(\.id))
            if !ids.isEmpty { pendingDeleteIDs = ids; confirmDelete = true }
        }
        .task {
            if let err = store.loadError {
                uploads.lastError = err
                store.loadError = nil
            }
        }
    }

    // MARK: Table

    private var fileTable: some View {
        @Bindable var store = store
        return Table(visibleFiles, selection: $store.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: file.name))
                        .foregroundStyle(.secondary)
                    Text(file.name)
                    if file.missing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .help("Not found on server")
                    }
                }
            }
            .width(min: 200)

            TableColumn("Size", value: \.size) { file in
                Text(file.size, format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("Sent", value: \.sentDate) { file in
                Text(file.sentDate, format: .dateTime.month(.abbreviated).day().year())
                    .foregroundStyle(.secondary)
            }
            .width(110)

            TableColumn("Age", value: \.sentDate) { file in
                AgeBadge(file: file, account: store.currentAccount)
            }
            .width(70)
        }
        .contextMenu(forSelectionType: SentFile.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            copyLinks(ids: ids)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter files")
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<SentFile.ID>) -> some View {
        Button("Copy Link") { copyLinks(ids: ids) }
        Button("Open in Browser") {
            urls(for: ids).forEach { NSWorkspace.shared.open($0) }
        }
        Button("Compose Email") { composeEmail(urls: urls(for: ids)) }
        Divider()
        Button("Delete from Server…", role: .destructive) {
            pendingDeleteIDs = ids
            confirmDelete = true
        }
        Button("Remove from List") {
            store.removeFiles(ids: ids)
        }
    }

    private func urls(for ids: Set<SentFile.ID>) -> [URL] {
        guard let account = store.currentAccount else { return [] }
        return store.currentFiles.filter { ids.contains($0.id) }
            .compactMap { account.downloadURL(for: $0) }
    }

    private func copyLinks(ids: Set<SentFile.ID>) {
        let links = urls(for: ids).map(\.absoluteString)
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    // MARK: Actions

    private func deleteSelection() {
        let ids = pendingDeleteIDs // captured at trigger time; immune to selection changing later
        Task {
            deleteErrors = await uploads.deleteRemote(ids: ids)
            showDeleteErrors = !deleteErrors.isEmpty
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await uploads.refresh()
            refreshing = false
        }
    }

    private func iconName(for fileName: String) -> String {
        switch URL(filePath: fileName).pathExtension.lowercased() {
        case "zip", "tgz", "gz", "tar", "dmg", "pkg": "shippingbox"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": "photo"
        case "mov", "mp4", "m4v", "avi", "mkv": "film"
        case "mp3", "m4a", "wav", "aiff", "flac": "music.note"
        case "pdf": "doc.richtext"
        case "txt", "md", "rtf": "doc.text"
        case "iso": "opticaldisc"
        case "": "folder"
        default: "doc"
        }
    }
}

// MARK: - Header (drop well + links)

struct HeaderBar: View {
    @Environment(Store.self) private var store
    @Environment(UploadManager.self) private var uploads
    let files: [SentFile]
    let account: Account?
    @State private var copied = false
    @State private var showQR = false

    private var links: [URL] {
        guard let account else { return [] }
        return files.compactMap { account.downloadURL(for: $0) }
    }
    private var joined: String { links.map(\.absoluteString).joined(separator: "\n") }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DropWell()

            VStack(alignment: .leading, spacing: 4) {
                Text("Links")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(linkText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .font(.callout.monospaced())
                        .foregroundStyle(links.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if links.count > 1 {
                        Text("+\(links.count - 1) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy",
                           systemImage: copied ? "checkmark" : "doc.on.doc",
                           action: copyAll)
                        .disabled(links.isEmpty)

                    Button("QR", systemImage: "qrcode", action: showQRCode)
                        .disabled(links.isEmpty)
                        .popover(isPresented: $showQR) {
                            QRView(text: links.first?.absoluteString ?? "")
                        }

                    Button("Open", systemImage: "safari", action: openAll)
                        .disabled(links.isEmpty)

                    Button("Email", systemImage: "envelope", action: emailAll)
                        .disabled(links.isEmpty)

                    Spacer()
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var linkText: String {
        if let first = links.first { return first.absoluteString }
        if files.isEmpty { return "Select a file — or drop one on the chute — to get its link" }
        return "No download URL — set one in Settings"
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func showQRCode() { showQR = true }
    private func openAll() { links.forEach { NSWorkspace.shared.open($0) } }
    private func emailAll() { composeEmail(urls: links) }
}

/// Always-visible drop well: quiet at rest, highlights only while a drag hovers it.
/// Click to choose files.
struct DropWell: View {
    @Environment(Store.self) private var store
    @Environment(UploadManager.self) private var uploads
    @State private var targeted = false

    private let iconGradient = LinearGradient(
        colors: [Color(red: 0.28, green: 0.20, blue: 0.85),
                 Color(red: 0.12, green: 0.55, blue: 0.96)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 5) {
            if uploads.activeJobs.isEmpty {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(iconGradient))
                    .rotationEffect(.degrees(-10))
                Text(targeted ? "Release to send" : "Drop files")
                    .font(.caption)
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Uploading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                               : AnyShapeStyle(.quaternary.opacity(0.5)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4]))
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            handleFileDrop(providers, uploads: uploads, store: store)
        }
        .onTapGesture { openPanel(uploads: uploads, store: store) }
        .help("Drop files or folders here to send them — or click to choose")
        .accessibilityLabel("Drop files here to send")
        .accessibilityAddTraits(.isButton)
    }
}

@MainActor
func handleFileDrop(_ providers: [NSItemProvider], uploads: UploadManager, store: Store) -> Bool {
    let account = store.currentAccount
    Task {
        var dropped: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    cont.resume(returning: url)
                }
            }
            if let url { dropped.append(url) }
        }
        if !dropped.isEmpty { uploads.send(dropped, to: account) }
    }
    return true
}

func composeEmail(urls: [URL]) {
    guard !urls.isEmpty else { return }
    let body = urls.map(\.absoluteString).joined(separator: "\n")
    var comps = URLComponents(string: "mailto:")!
    comps.queryItems = [URLQueryItem(name: "subject", value: urls.count == 1 ? "File for you" : "Files for you"),
                        URLQueryItem(name: "body", value: body)]
    if let url = comps.url { NSWorkspace.shared.open(url) }
}

@MainActor
func openPanel(uploads: UploadManager, store: Store) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.message = "Choose files or folders to send"
    panel.prompt = "Send"
    if panel.runModal() == .OK {
        uploads.send(panel.urls, to: store.currentAccount)
    }
}

// MARK: - QR popover

struct QRView: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            if let image = qrImage(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
            }
            Text("Scan to open on your phone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // CIContext is expensive; share one across renders
    private static let context = CIContext()

    private func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = Self.context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

// MARK: - Age badge

struct AgeBadge: View {
    let file: SentFile
    let account: Account?

    var body: some View {
        let days = file.ageDays
        let expire = account?.expireDays ?? 0
        let color: Color = {
            guard expire > 0 else { return .secondary }
            if days >= expire { return .red } // matches isExpired's >= so the badge agrees with deletion
            if Double(days) >= Double(expire) * 0.75 { return .orange }
            return .secondary
        }()
        Text("\(days)d")
            .font(.callout.monospacedDigit())
            .foregroundStyle(color)
            .help(expire > 0 ? "Expires after \(expire) days" : "Never expires")
    }
}

// MARK: - Drop overlay

struct DropOverlay: View {
    let accountName: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("Drop to send" + (accountName.map { " to “\($0)”" } ?? ""))
                    .font(.title3.weight(.medium))
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @Environment(Store.self) private var store
    @Environment(UploadManager.self) private var uploads
    @Binding var refreshing: Bool
    let itemCount: Int
    let refresh: () -> Void
    @State private var showJobs = false

    var body: some View {
        @Bindable var store = store

        HStack(spacing: 12) {
            Picker("Account", selection: $store.selectedAccountID) {
                ForEach(store.accounts) { account in
                    Text(account.name).tag(Optional(account.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(store.accounts.isEmpty)
            .onChange(of: store.selectedAccountID) { store.save() }

            Spacer()

            if uploads.activeJobs.isEmpty {
                Text("^[\(itemCount) item](inflect: true)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showJobs = true
                } label: {
                    HStack(spacing: 8) {
                        if let progress = uploads.overallProgress {
                            ProgressView(value: progress).frame(width: 140)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(uploads.activeJobs.first?.displayName ?? "")
                            .font(.callout)
                            .lineLimit(1)
                            .frame(maxWidth: 180)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showJobs) { JobsPopover() }

                Button("Cancel") { uploads.cancelAll() }
                    .controlSize(.small)
            }

            Spacer()

            if uploads.jobs.contains(where: { if case .failed = $0.status { true } else { false } }) {
                Button("Failed Uploads", systemImage: "exclamationmark.circle.fill") {
                    showJobs = true
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .help("Some uploads failed")
                .popover(isPresented: $showJobs) { JobsPopover() }
            }

            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(refreshing || store.accounts.isEmpty)
                .opacity(refreshing ? 0 : 1)
                .overlay { if refreshing { ProgressView().controlSize(.small) } }
                .help("Load the server’s file list and sync sizes and ages")

            Button("Send Files…", systemImage: "plus", action: chooseFiles)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(store.accounts.isEmpty)
                .help("Choose files to send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chooseFiles() {
        openPanel(uploads: uploads, store: store)
    }
}

struct JobsPopover: View {
    @Environment(UploadManager.self) private var uploads

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(uploads.jobs) { job in
                HStack(spacing: 8) {
                    statusIcon(job)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.displayName).font(.callout).lineLimit(1)
                        if case .failed(let msg) = job.status {
                            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                        } else if job.status == .archiving {
                            Text("Archiving…").font(.caption).foregroundStyle(.secondary)
                        } else if let progress = job.progress, job.status == .uploading {
                            ProgressView(value: progress).frame(width: 200)
                        }
                    }
                    Spacer()
                    if !job.isActive {
                        Button("Dismiss", systemImage: "xmark.circle.fill") {
                            uploads.dismissJob(job.id)
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.plain)
                    }
                }
            }
            if uploads.jobs.isEmpty {
                Text("No uploads").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private func statusIcon(_ job: UploadJob) -> some View {
        switch job.status {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .archiving: Image(systemName: "shippingbox").foregroundStyle(.blue)
        case .uploading: Image(systemName: "arrow.up.circle").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Ask sheet (wrap decision)

struct AskSheet: View {
    @Environment(UploadManager.self) private var uploads
    @State var request: AskRequest
    @State private var wrap = true

    private var itemSummary: String {
        if request.urls.count == 1 {
            return request.urls[0].lastPathComponent
        }
        return "\(request.urls.count) items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Send \(itemSummary)", systemImage: "paperplane.fill")
                .font(.title3.weight(.semibold))

            if request.canSendAsIs {
                Picker("", selection: $wrap) {
                    Text(request.urls.count > 1 ? "As one archive" : "As an archive").tag(true)
                    Text(request.urls.count > 1 ? "Individually" : "As-is").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if wrap || !request.canSendAsIs {
                Form {
                    TextField("Archive name:", text: $request.suggestedName)
                    Picker("Format:", selection: $request.archiveType) {
                        ForEach(ArchiveType.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 220)
                    SecureField("Password (optional):", text: $request.archivePassword)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { uploads.cancelAsk() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { uploads.resolveAsk(request, wrap: wrap || !request.canSendAsIs) }
                    .keyboardShortcut(.defaultAction)
                    .disabled((wrap || !request.canSendAsIs) && request.suggestedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
