import Foundation
import AppKit
import Observation

/// Checks GitHub Releases for a newer version and can download + install it in place
/// (download DMG → swap the app bundle via a detached helper → relaunch). No Sparkle dependency;
/// the trade-off is no silent background updates.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Set when a release newer than the running version exists.
    var newerVersion: String?
    var releaseURL: URL?
    var dmgURL: URL?
    var installing = false
    var installError: String?

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
            dmgURL = (json["assets"] as? [[String: Any]])?
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".dmg") }
                .flatMap(URL.init)
        }
    }

    func dismiss() { newerVersion = nil }

    // MARK: In-place install

    /// Downloads the release DMG, mounts it, and swaps the running app bundle, then relaunches.
    /// Falls back to opening the DMG if the app isn't in a writable location.
    func downloadAndInstall() async {
        guard let dmgURL else {
            if let releaseURL { NSWorkspace.shared.open(releaseURL) }
            return
        }
        installing = true
        installError = nil
        defer { installing = false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: dmgURL)
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Sendling-update.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmp, to: dmg)

            let mount = try await mountDMG(dmg)
            let newApp = mount.appendingPathComponent("Sendling.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                throw TransferError(message: "The update disk image didn’t contain Sendling.app.")
            }
            let currentApp = Bundle.main.bundleURL
            let parent = currentApp.deletingLastPathComponent().path
            if FileManager.default.isWritableFile(atPath: parent) {
                try launchSwapHelper(newApp: newApp, currentApp: currentApp, mount: mount, dmg: dmg)
                NSApp.terminate(nil) // helper waits for exit, swaps, relaunches
            } else {
                NSWorkspace.shared.open(mount) // read-only location — let the user drag it in
            }
        } catch {
            installError = error.localizedDescription
        }
    }

    private func mountDMG(_ dmg: URL) async throws -> URL {
        let out = try await ProcessRunner().run("/usr/bin/hdiutil",
                                                ["attach", "-nobrowse", "-noautoopen", dmg.path])
        // Last whitespace-run field of the last line is the /Volumes mount point.
        for line in out.split(separator: "\n").reversed() {
            if let range = line.range(of: "/Volumes/") {
                return URL(fileURLWithPath: String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        throw TransferError(message: "Couldn’t mount the update disk image.")
    }

    /// Writes and launches a detached shell helper that waits for this app to quit, replaces the
    /// bundle, detaches the DMG, and relaunches — the classic no-Sparkle self-update.
    private func launchSwapHelper(newApp: URL, currentApp: URL, mount: URL, dmg: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.4; done
        rm -rf \(shq(currentApp.path))
        cp -R \(shq(newApp.path)) \(shq(currentApp.path))
        xattr -dr com.apple.quarantine \(shq(currentApp.path)) 2>/dev/null
        hdiutil detach \(shq(mount.path)) -quiet 2>/dev/null
        rm -f \(shq(dmg.path))
        open \(shq(currentApp.path))
        """
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("sendling-update-\(pid).sh")
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [helper.path]
        try p.run() // detached; we don't wait — we're about to terminate
    }

    /// Single-quote a path for /bin/sh (paths may contain spaces).
    private func shq(_ s: String) -> String { "'" + s.replacing("'", with: "'\\''") + "'" }

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
