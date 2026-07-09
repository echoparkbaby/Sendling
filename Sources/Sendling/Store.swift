import Foundation
import Observation
import Security

// MARK: - Keychain (passwords never touch the JSON store)

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Sendling",
         kSecAttrAccount as String: key]
    }

    // ponytail: passwords stay local per-Mac. iCloud Keychain (kSecAttrSynchronizable) needs a
    // keychain-access-groups entitlement that a hand-signed Developer ID app can't carry without
    // App Store provisioning — it fails with errSecMissingEntitlement (-34018). Secrets never
    // leaving the machine is also a security win; accounts/history still sync via iCloud Drive.
    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

// MARK: - Store

@MainActor
@Observable
final class Store {
    static let shared = Store()

    var accounts: [Account] = []
    var files: [SentFile] = []
    var selectedAccountID: UUID? {
        didSet {
            // Selection points at rows of one account's list; switching accounts must clear it
            // or the Delete key would act on now-invisible files from the previous account.
            if oldValue != selectedAccountID { selection.removeAll() }
        }
    }
    var selection = Set<SentFile.ID>()
    /// Set when an existing data.json couldn't be decoded (it was preserved as data.json.bak).
    var loadError: String?

    var currentAccount: Account? {
        accounts.first(where: { $0.id == selectedAccountID }) ?? accounts.first
    }

    var currentFiles: [SentFile] {
        guard let account = currentAccount else { return [] }
        return files.filter { $0.accountID == account.id }
    }

    var iCloudSyncEnabled: Bool { UserDefaults.standard.bool(forKey: "iCloudSync") }
    var iCloudAvailable: Bool { Sendling.iCloudDir != nil }
    /// True when another Mac has already synced Sendling data into iCloud Drive.
    var iCloudDataAvailable: Bool {
        guard let url = iCloudDataURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var localDataURL: URL { Sendling.supportDir.appendingPathComponent("data.json") }
    private var iCloudDataURL: URL? { Sendling.iCloudDir?.appendingPathComponent("data.json") }
    /// Active store file — iCloud Drive when sync is on and available, else local.
    private var dataURL: URL {
        (iCloudSyncEnabled ? iCloudDataURL : nil) ?? localDataURL
    }

    private struct Persisted: Codable {
        var accounts: [Account]
        var files: [SentFile]
        var selectedAccountID: UUID?
    }

    private init() {
        try? FileManager.default.createDirectory(at: Sendling.supportDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: dataURL) else { return } // first launch / evicted
        do {
            let p = try Self.decoder.decode(Persisted.self, from: data)
            accounts = p.accounts
            files = p.files
            selectedAccountID = p.selectedAccountID ?? p.accounts.first?.id
        } catch {
            // Don't silently start fresh over the top of it: preserve the file for recovery
            // (the next save() would otherwise overwrite all accounts + history) and report.
            let backup = dataURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: dataURL, to: backup)
            loadError = "Your Sendling data couldn’t be read and was set aside as data.json.bak. "
                + "Accounts and history were reset. (\(error.localizedDescription))"
        }
    }

    /// Re-read the store — picks up changes another Mac synced via iCloud.
    /// ponytail: called on app activation (covers the switch-Macs workflow); an NSMetadataQuery
    /// would give live updates while both Macs are open, add it if that's ever needed.
    func reload() {
        guard iCloudSyncEnabled else { return }
        load()
    }

    /// Turns iCloud sync on/off, migrating the data file and passwords.
    func setiCloudSync(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "iCloudSync") // flips which dataURL is active
        if on, let dir = Sendling.iCloudDir, let cloud = iCloudDataURL {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cloud.path) {
                load()  // another Mac already has data — adopt it
            } else {
                save()  // first device — push current data up to iCloud
            }
        } else {
            save()  // sync off — write current data back to the local store
        }
    }

    func save() {
        if iCloudSyncEnabled, let dir = Sendling.iCloudDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let p = Persisted(accounts: accounts, files: files, selectedAccountID: selectedAccountID)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? (try? enc.encode(p))?.write(to: dataURL, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Accounts

    func password(for account: Account) -> String {
        Keychain.get(account.id.uuidString)
    }

    func setPassword(_ pw: String, for account: Account) {
        Keychain.set(pw, for: account.id.uuidString)
    }

    func addAccount() -> Account {
        let account = Account()
        accounts.append(account)
        if selectedAccountID == nil { selectedAccountID = account.id }
        save()
        return account
    }

    func duplicate(_ account: Account) -> Account {
        var copy = account
        copy.id = UUID()
        copy.name += " copy"
        Keychain.set(password(for: account), for: copy.id.uuidString)
        accounts.append(copy)
        save()
        return copy
    }

    func remove(_ account: Account) {
        Keychain.delete(account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        files.removeAll { $0.accountID == account.id }
        if selectedAccountID == account.id { selectedAccountID = accounts.first?.id }
        save()
    }

    func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        save()
    }

    // MARK: Files

    func add(_ file: SentFile) {
        // Replace any prior row for the same account+name so a re-upload doesn't leave a stale
        // duplicate whose expiry would later delete the freshly-uploaded remote file.
        files.removeAll { $0.accountID == file.accountID && $0.name == file.name }
        files.append(file)
        selection = [file.id] // fresh upload's link shows in the header
        save()
    }

    func setLink(_ id: SentFile.ID, _ link: String) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        files[i].link = link
        save()
    }

    func rename(_ id: SentFile.ID, to newName: String) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        files[i].name = newName
        files[i].link = nil // derived URLs follow the name; API links get re-fetched
        save()
    }

    func removeFiles(ids: Set<SentFile.ID>) {
        files.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func markMissing(_ id: SentFile.ID, missing: Bool) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        files[i].missing = missing
        save()
    }

    /// Merges a remote directory listing into the history: updates sizes, flags
    /// files that vanished, and adds files uploaded from elsewhere (or by FileChute).
    func reconcile(accountID: UUID, remote: [RemoteEntry]) {
        let remoteByName = Dictionary(remote.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var known = Set<String>()
        for i in files.indices where files[i].accountID == accountID {
            known.insert(files[i].name)
            if let entry = remoteByName[files[i].name] {
                files[i].size = entry.size
                files[i].missing = false
            } else {
                files[i].missing = true
            }
        }
        for entry in remote where !known.contains(entry.name) {
            files.append(SentFile(accountID: accountID, name: entry.name,
                                  size: entry.size, sentDate: entry.modified ?? .now))
        }
        save()
    }

    var expiredFiles: [SentFile] {
        files.filter { file in
            guard let account = accounts.first(where: { $0.id == file.accountID }) else { return false }
            return file.isExpired(in: account)
        }
    }
}
