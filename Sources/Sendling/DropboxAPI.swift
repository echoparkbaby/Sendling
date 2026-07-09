import Foundation
import CryptoKit

/// Dropbox v2 API: OAuth PKCE (code copy-paste, no redirect server), uploads via curl,
/// share links + listing via URLSession RPC calls.
enum DropboxAPI {
    // MARK: OAuth

    struct PKCE {
        let verifier: String
        let challenge: String
    }

    static func makePKCE() -> PKCE {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        let verifier = String((0..<64).compactMap { _ in chars.randomElement() })
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PKCE(verifier: verifier, challenge: challenge)
    }

    static func authorizeURL(appKey: String, challenge: String) -> URL {
        URL(string: "https://www.dropbox.com/oauth2/authorize?client_id=\(appKey)&response_type=code"
            + "&code_challenge=\(challenge)&code_challenge_method=S256&token_access_type=offline")!
    }

    /// Exchanges the pasted authorization code for a long-lived refresh token.
    static func exchangeCode(_ code: String, appKey: String, verifier: String) async throws -> String {
        let json = try await postForm(
            body: "code=\(code.trimmingCharacters(in: .whitespacesAndNewlines))"
                + "&grant_type=authorization_code&client_id=\(appKey)&code_verifier=\(verifier)")
        guard let token = json["refresh_token"] as? String else {
            throw TransferError(message: (json["error_description"] as? String) ?? "Dropbox authorization failed")
        }
        return token
    }

    // Short-lived access tokens, cached per refresh token.
    // Lock use lives in sync helpers — NSLock is illegal across awaits.
    private static let cacheLock = NSLock()
    private static var tokenCache: [String: (token: String, expiry: Date)] = [:]

    private static func cachedToken(for refreshToken: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let hit = tokenCache[refreshToken], hit.expiry > Date.now.addingTimeInterval(60) else { return nil }
        return hit.token
    }

    private static func cacheToken(_ token: String, ttl: Double, for refreshToken: String) {
        cacheLock.lock()
        tokenCache[refreshToken] = (token, Date.now.addingTimeInterval(ttl))
        cacheLock.unlock()
    }

    static func accessToken(appKey: String, refreshToken: String) async throws -> String {
        if let cached = cachedToken(for: refreshToken) { return cached }

        let json = try await postForm(
            body: "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(appKey)")
        guard let token = json["access_token"] as? String else {
            throw TransferError(message: "Dropbox session expired — reconnect the account in Settings")
        }
        cacheToken(token, ttl: (json["expires_in"] as? Double) ?? 14400, for: refreshToken)
        return token
    }

    private static func postForm(body: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: RPC

    static func rpc(_ endpoint: String, args: [String: Any], token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Endpoints that take no arguments (e.g. users/get_current_account) require a null body,
        // not {} — sending {} is a 400.
        req.httpBody = args.isEmpty ? Data("null".utf8) : (try JSONSerialization.data(withJSONObject: args))
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let summary = json["error_summary"] as? String {
            throw TransferError(message: "Dropbox: \(summary)")
        }
        // Non-JSON bodies (plain-text 400s, proxy/outage HTML 5xx) parse to [:]; without a
        // status check they'd read as success — refresh would mark every file missing and
        // delete would silently no-op. Trust the HTTP status.
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(decoding: data, as: UTF8.self).prefix(200)
            throw TransferError(message: "Dropbox HTTP \(http.statusCode): \(body)")
        }
        return json
    }

    /// "/dir/name" path inside the Dropbox; "" is the root.
    static func apiPath(dir: String, name: String? = nil) -> String {
        var parts = dir.split(separator: "/").map(String.init)
        if let name { parts.append(name) }
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    /// `expiresDays` requires Dropbox Professional/Business — on free plans the create call
    /// errors and we fall back to a plain existing link.
    static func shareLink(path: String, token: String, expiresDays: Int? = nil) async throws -> String {
        var settings: [String: Any] = [:]
        if let expiresDays, expiresDays > 0,
           let date = Calendar.current.date(byAdding: .day, value: expiresDays, to: .now) {
            settings["expires"] = ISO8601DateFormatter().string(from: date)
        }

        func existingLink() async -> String? {
            guard let e = try? await rpc("sharing/list_shared_links",
                                         args: ["path": path, "direct_only": true], token: token),
                  let links = e["links"] as? [[String: Any]] else { return nil }
            return links.first?["url"] as? String
        }

        // No protection requested → reuse an existing link if there is one.
        if settings.isEmpty, let url = await existingLink() { return url }

        let args: [String: Any] = settings.isEmpty ? ["path": path] : ["path": path, "settings": settings]
        do {
            let created = try await rpc("sharing/create_shared_link_with_settings", args: args, token: token)
            guard let url = created["url"] as? String else {
                throw TransferError(message: "Dropbox didn’t return a share link")
            }
            return url
        } catch {
            // Already shared, or settings unsupported on this plan — use the existing link.
            if let url = await existingLink() { return url }
            throw error
        }
    }

    /// Inspects a `files/upload` response (body + "SENDLING_HTTP:<code>" from curl -w) and throws
    /// Dropbox's actual error on non-2xx so the user sees why (bad scope, path conflict, etc.).
    static func checkUploadResponse(_ out: String) throws {
        guard let marker = out.range(of: "SENDLING_HTTP:") else { return } // no status → assume ok
        let code = Int(out[marker.upperBound...].prefix(3)) ?? 0
        if (200...299).contains(code) { return }
        let body = String(out[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let summary = json["error_summary"] as? String {
            throw TransferError(message: "Dropbox: \(summary)")
        }
        throw TransferError(message: "Dropbox HTTP \(code)" + (body.isEmpty ? "" : ": \(body.prefix(200))"))
    }

    static func parseEntries(_ json: [String: Any]) -> [RemoteEntry] {
        let iso = ISO8601DateFormatter()
        return ((json["entries"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            // Files only — a "folder" tag would otherwise become a sent-file row that
            // Delete Expired deletes recursively and Refresh publishes a public link for.
            guard (entry[".tag"] as? String) == "file" else { return nil }
            let size = (entry["size"] as? Int64) ?? Int64(entry["size"] as? Int ?? 0)
            return RemoteEntry(name: name,
                               size: size,
                               modified: (entry["server_modified"] as? String).flatMap { iso.date(from: $0) })
        }
    }

    /// Dropbox-API-Arg headers must be ASCII; escape everything else as \uXXXX.
    static func headerSafeJSON(_ obj: [String: Any]) -> String {
        let raw = String(decoding: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), as: UTF8.self)
        var out = ""
        for scalar in raw.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                out.unicodeScalars.append(scalar)
            } else if scalar.value > 0xFFFF {
                let v = scalar.value - 0x10000
                out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
            } else {
                out += String(format: "\\u%04x", scalar.value)
            }
        }
        return out
    }
}
