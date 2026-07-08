import Foundation

/// One-time migration of accounts from FileChute (com.yellowmug.FileChute.plist).
/// Passwords stay in FileChute's keychain items — the user re-enters them once.
enum FileChuteImport {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.yellowmug.FileChute.plist")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func importAccounts() -> [Account] {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let configs = plist["Configurations2"] as? [[String: Any]]
        else { return [] }

        return configs.compactMap { config in
            guard let name = config["AccountName"] as? String else { return nil }
            // FileChute AccountType 2 = FTP; skip anything else (e.g. Dropbox) rather than
            // importing it as a broken FTP account with a meaningless host.
            guard (config["AccountType"] as? Int) == 2 else { return nil }
            var account = Account()
            account.name = name
            account.type = .ftp

            // The actual upload target lives in UploadURL (Hostname is display-only)
            if let uploadURL = config["UploadURL"] as? String,
               let comps = URLComponents(string: uploadURL) {
                account.host = comps.host ?? (config["Hostname"] as? String ?? "")
                account.port = comps.port
                account.remoteDir = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                account.host = config["Hostname"] as? String ?? ""
            }

            account.username = config["Username"] as? String ?? ""
            account.downloadURLBase = (config["DowndloadURL"] as? String) ?? "" // sic — FileChute's typo
            account.expireDays = config["Expiration"] as? Int ?? 0
            account.timeoutSeconds = config["ConnectionTimeout"] as? Int ?? 60
            account.excludeDSStore = config["ExcludeDSStore"] as? Bool ?? true
            account.archivePassword = config["ArchiveDefaultPassword"] as? String ?? ""
            account.neverWrapExtensions = config["NeverWrapExtensions"] as? String ?? account.neverWrapExtensions

            // Calibrated against FileChute's UI: 0 = always, 1 = never, 2 = ask
            switch config["SendFileOption"] as? Int {
            case 0: account.fileWrapPolicy = .always
            case 2: account.fileWrapPolicy = .ask
            default: account.fileWrapPolicy = .never
            }
            // 0 = always wrap, 1 = ask
            account.folderWrapPolicy = (config["SendFolderOption"] as? Int == 0) ? .always : .ask

            // 0 = folder name, 1 = random, 2 = folder + random
            switch config["ArchiveDefaultName"] as? Int {
            case 1: account.archiveNaming = .randomString
            case 2: account.archiveNaming = .itemNamePlusRandom
            default: account.archiveNaming = .itemName
            }

            account.archiveType = .zip // FileChute's dmg/tar variants map fine to the default
            return account
        }
    }
}
