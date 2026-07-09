import Foundation

/// Nextcloud: transfers ride the WebDAV endpoint; public share links come from the OCS API.
enum NextcloudAPI {
    /// "https://cloud.example.com" from whatever the user typed in the host field.
    static func baseURL(_ account: Account) -> String {
        var base = account.host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !base.isEmpty, !base.contains("://") { base = "https://" + base }
        return base
    }

    /// WebDAV URL for a path inside the user's files ("" = the account's remote dir itself).
    static func davURL(_ account: Account, name: String? = nil) -> String {
        var parts = account.remoteDir.split(separator: "/").map(String.init)
        if let name { parts.append(name) }
        let path = parts
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return baseURL(account) + "/remote.php/dav/files/\(account.username)" + (path.isEmpty ? "" : "/\(path)")
    }

    // MARK: Share links (OCS)

    /// Path-safe encoding for both the GET query and the POST form body: unlike
    /// .urlQueryAllowed this escapes & + = so `a&b.zip` / `report+2026.zip` aren't
    /// split by the server into the wrong (or an unrelated existing) path.
    private static let pathValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-._~")

    static func shareLink(for name: String, account: Account, password: String) async throws -> String {
        let path = "/" + (account.remoteDir.split(separator: "/") + [Substring(name)]).joined(separator: "/")
        let ocsBase = baseURL(account) + "/ocs/v2.php/apps/files_sharing/api/v1/shares"

        // Reuse an existing public link if there is one
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: pathValueAllowed) ?? path
        if let existing = try? await ocs("GET", url: "\(ocsBase)?path=\(encodedPath)&reshares=false",
                                         account: account, password: password),
           let url = firstTag("url", in: existing) {
            return url
        }

        var body = "path=\(encodedPath)&shareType=3"
        if let days = account.linkExpireDays, days > 0,
           let date = Calendar.current.date(byAdding: .day, value: days, to: .now) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            body += "&expireDate=\(fmt.string(from: date))"
        }
        let created = try await ocs("POST", url: ocsBase, body: body, account: account, password: password)
        guard let url = firstTag("url", in: created) else {
            throw TransferError(message: "Nextcloud didn’t return a share link" +
                                (firstTag("message", in: created).map { ": \($0)" } ?? ""))
        }
        return url
    }

    private static func ocs(_ method: String, url: String, body: String? = nil,
                            account: Account, password: String) async throws -> String {
        guard let requestURL = URL(string: url) else { throw TransferError(message: "Bad Nextcloud URL") }
        var req = URLRequest(url: requestURL, timeoutInterval: TimeInterval(account.timeoutSeconds))
        req.httpMethod = method
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        let auth = Data("\(account.username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            throw TransferError(message: "Nextcloud rejected the login — use an app password")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: PROPFIND listing

    static func list(account: Account, password: String, runner: ProcessRunner) async throws -> [RemoteEntry] {
        // Credentials via -K stdin, not argv (ps-visible); see Transfer.runCurl.
        let xml = try await runner.run("/usr/bin/curl",
                                       ["-K", "-", "-sS", "--fail", "--connect-timeout", "\(account.timeoutSeconds)",
                                        "-X", "PROPFIND", "-H", "Depth: 1",
                                        davURL(account) + "/"],
                                       stdin: Data(Transfer.basicAuthConfig(account, password: password).utf8))
        return parsePropfind(xml)
    }

    /// ponytail: regex over Nextcloud's stable PROPFIND XML; a full XMLParser if other DAV servers join.
    static func parsePropfind(_ xml: String) -> [RemoteEntry] {
        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        var entries: [RemoteEntry] = []
        // Split into <d:response> blocks; first block is the directory itself
        let blocks = xml.components(separatedBy: "<d:response>").dropFirst().dropFirst()
        for block in blocks {
            guard let href = firstTag("href", in: block) else { continue }
            // Skip collections: a subfolder's href ends in "/" and it carries <d:collection/>.
            // Admitting them would let Delete Expired recursively wipe a whole folder, and
            // Refresh auto-publish a public share link to all of its contents.
            if href.hasSuffix("/") || block.contains("<d:collection/>") { continue }
            guard let name = href.removingPercentEncoding?
                      .split(separator: "/").last.map(String.init)
            else { continue }
            let size = firstTag("getcontentlength", in: block).flatMap(Int64.init) ?? 0
            let modified = firstTag("getlastmodified", in: block).flatMap { httpDate.date(from: $0) }
            entries.append(RemoteEntry(name: name, size: size, modified: modified))
        }
        return entries
    }

    /// First "<ns:tag ...>value</ns:tag>" value in an XML string, any namespace prefix.
    static func firstTag(_ tag: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<[a-zA-Z0-9]*:?\(tag)[^>]*>([^<]+)</[a-zA-Z0-9]*:?\(tag)>"),
            let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
            let range = Range(match.range(at: 1), in: xml)
        else { return nil }
        // &amp; is the only entity that occurs in the hrefs/URLs we extract
        return String(xml[range]).replacing("&amp;", with: "&")
    }
}
