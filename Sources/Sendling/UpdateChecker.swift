import Foundation
import Observation

/// Checks GitHub Releases for a newer version and surfaces a banner. Not an auto-installer —
/// a real one needs Sparkle (a dependency); this just points the user at the download.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Set when a release newer than the running version exists.
    var newerVersion: String?
    var releaseURL: URL?

    private static let latestAPI = URL(string: "https://api.github.com/repos/echoparkbaby/Sendling/releases/latest")!

    func check() async {
        var req = URLRequest(url: Self.latestAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isNewer(latest, than: Sendling.version) {
            newerVersion = latest
            releaseURL = (json["html_url"] as? String).flatMap(URL.init) ?? Sendling.releasesURL
        }
    }

    func dismiss() { newerVersion = nil }

    /// Numeric dot-version compare: "1.0.10" > "1.0.9".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
