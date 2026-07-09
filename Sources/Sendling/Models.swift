import Foundation

// MARK: - Constants

enum Sendling {
    /// Single source of truth is Info.plist; "dev" appears under `swift run` (no bundle).
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let projectURL = URL(string: "https://github.com/echoparkbaby/Sendling")!
    static let releasesURL = URL(string: "https://github.com/echoparkbaby/Sendling/releases")!

    static let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sendling")

    /// The user's iCloud Drive "Sendling" folder, or nil if iCloud Drive isn't enabled.
    /// Plain file I/O here syncs across the user's Macs — no ubiquity-container entitlement.
    static var iCloudDir: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Sendling")
    }
}

// MARK: - Account

enum AccountType: String, Codable, CaseIterable, Identifiable {
    case sftp = "SFTP"
    case ftp = "FTP"
    case ftps = "FTPS"
    case webdav = "WebDAV"
    case nextcloud = "Nextcloud"
    case dropbox = "Dropbox"
    var id: String { rawValue }

    var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftp, .ftps: 21
        case .webdav, .nextcloud, .dropbox: 443
        }
    }

    /// Share links come from the provider's API instead of a public download URL.
    var linksFromAPI: Bool { self == .dropbox || self == .nextcloud }
}

enum ArchiveType: String, Codable, CaseIterable, Identifiable {
    case zip, targz, dmg
    var id: String { rawValue }

    var label: String {
        switch self {
        case .zip: "zip"
        case .targz: "tar.gz"
        case .dmg: "dmg"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .targz: "tgz"
        case .dmg: "dmg"
        }
    }
}

enum WrapPolicy: String, Codable, CaseIterable, Identifiable {
    case always, never, ask
    var id: String { rawValue }
}

enum ArchiveNaming: String, Codable, CaseIterable, Identifiable {
    case itemName, randomString, itemNamePlusRandom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .itemName: "Item name"
        case .randomString: "Random string"
        case .itemNamePlusRandom: "Item name + random string"
        }
    }
}

struct Account: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "New Account"
    var type: AccountType = .sftp
    var host = ""
    var port: Int? = nil
    var username = ""
    /// Directory on the server, relative to the login root (e.g. "public_html/files").
    var remoteDir = ""
    /// Public base URL where uploads become reachable (e.g. "https://example.com/files").
    var downloadURLBase = ""
    var timeoutSeconds = 60
    /// 0 = never expire.
    var expireDays = 0
    var archiveType: ArchiveType = .zip
    var archivePassword = ""
    var archiveNaming: ArchiveNaming = .itemName
    var excludeDSStore = true
    var fileWrapPolicy: WrapPolicy = .never
    var neverWrapExtensions = "zip tar gz tgz dmg pkg"
    /// Folders are always archived; .ask means confirm name/format first.
    var folderWrapPolicy: WrapPolicy = .always
    /// "Help me fill in the URL below" — optional so pre-existing data.json still decodes.
    var urlAssist: Bool? = nil
    /// Dropbox OAuth app key (PKCE public client — not a secret).
    /// Optional in storage so pre-existing data.json still decodes.
    var dropboxAppKey: String? = nil

    /// Non-optional binding surface for the settings form.
    var dropboxAppKeyValue: String {
        get { dropboxAppKey ?? "" }
        set { dropboxAppKey = newValue.trimmingCharacters(in: .whitespaces) }
    }

    var effectivePort: Int { port ?? type.defaultPort }

    /// Link for a sent file: API-provided share link when present, else derived from the base URL.
    func downloadURL(for file: SentFile) -> URL? {
        if let link = file.link { return URL(string: link) }
        return downloadURL(for: file.name)
    }

    /// Download URL for a stored file name.
    func downloadURL(for fileName: String) -> URL? {
        let base = downloadURLBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty,
              let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: base + "/" + encoded)
    }

    var suggestedDownloadURL: String {
        // ponytail: heuristic (strip ftp./www. host prefix, cPanel public_html web root);
        // real setups vary — assist can be turned off and the field edited
        var domain = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if domain.contains("://") {
            domain = String(domain.drop(while: { $0 != ":" }).dropFirst(3))
        }
        for prefix in ["ftp.", "sftp.", "www."] where domain.hasPrefix(prefix) {
            domain = String(domain.dropFirst(prefix.count))
        }
        var dir = remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if dir == "public_html" {
            dir = ""
        } else if dir.hasPrefix("public_html/") {
            dir = String(dir.dropFirst("public_html/".count))
        }
        return "https://\(domain)" + (dir.isEmpty ? "" : "/\(dir)")
    }

    /// Read-only preview of where uploads go, derived from the connection fields.
    var uploadURLPreview: String {
        let dir = remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = dir.isEmpty ? "" : "/\(dir)"
        switch type {
        case .ftp: return "ftp://\(host):\(effectivePort)\(path)"
        case .ftps: return "ftps://\(host):\(effectivePort)\(path)"
        case .sftp: return "sftp://\(username.isEmpty ? "" : username + "@")\(host):\(effectivePort)\(path)"
        case .webdav:
            var base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if !base.isEmpty, !base.contains("://") { base = "https://" + base }
            return base + path
        case .nextcloud:
            var base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if !base.isEmpty, !base.contains("://") { base = "https://" + base }
            return base + "/remote.php/dav/files/\(username)\(path)"
        case .dropbox:
            return "Dropbox\(path.isEmpty ? "" : " › " + path)"
        }
    }

    var neverWrapExtensionSet: Set<String> {
        Set(neverWrapExtensions.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
    }
}

// MARK: - Sent file

struct SentFile: Identifiable, Codable, Hashable {
    var id = UUID()
    var accountID: UUID
    var name: String
    var size: Int64
    var sentDate: Date
    /// Set by Refresh when the file is no longer reachable on the server.
    var missing = false
    /// API-provided share link (Dropbox/Nextcloud); nil for URL-derived accounts.
    var link: String? = nil

    var ageDays: Int {
        Calendar.current.dateComponents([.day], from: sentDate, to: .now).day ?? 0
    }

    func isExpired(in account: Account) -> Bool {
        // "expire after N days" → gone once N full days have elapsed (>=, not >)
        account.expireDays > 0 && ageDays >= account.expireDays
    }
}
