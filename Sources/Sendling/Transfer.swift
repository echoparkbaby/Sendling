import Foundation

// MARK: - Subprocess plumbing
// ponytail: the whole protocol layer is /usr/bin/curl + /usr/bin/sftp.
// Native NWConnection FTP/SFTP if these ever fall short.

struct TransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemoteEntry {
    let name: String
    let size: Int64
    let modified: Date?
}

final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var launched = false
    private(set) var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if launched { process?.terminate() } // terminate() on an unlaunched Process throws
    }

    /// Sync (NSLock can't span awaits): registers the process unless already cancelled.
    private func register(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    /// Marks the process launched; if cancel() raced in during setup, terminate now.
    private func markLaunched() {
        lock.lock(); defer { lock.unlock() }
        launched = true
        if cancelled { process?.terminate() }
    }

    /// Runs a tool, returns combined output. `onStderr` receives raw stderr chunks (curl progress).
    /// `stdin` is written after launch and closed (small payloads like passwords).
    @discardableResult
    func run(_ launchPath: String,
             _ args: [String],
             cwd: URL? = nil,
             env: [String: String] = [:],
             stdin: Data? = nil,
             onStderr: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let p = Process()
        guard register(p) else { throw CancellationError() }

        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if !env.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe { p.standardInput = inPipe }

        let outBuf = LockedBuffer(), errBuf = LockedBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            outBuf.append(h.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            errBuf.append(data)
            if let s = String(data: data, encoding: .utf8), !s.isEmpty { onStderr?(s) }
        }

        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let out = outBuf.string, err = errBuf.string
                if self?.cancelled == true {
                    cont.resume(throwing: CancellationError())
                } else if proc.terminationStatus == 0 {
                    cont.resume(returning: out + err)
                } else {
                    let detail = err.split(separator: "\n").last.map(String.init) ?? "exit \(proc.terminationStatus)"
                    cont.resume(throwing: TransferError(message: detail))
                }
            }
            do {
                try p.run()
                markLaunched()
                if let inPipe, let stdin {
                    inPipe.fileHandleForWriting.write(stdin)
                    inPipe.fileHandleForWriting.closeFile()
                }
            } catch {
                cont.resume(throwing: TransferError(message: error.localizedDescription))
            }
        }
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// MARK: - Transfer operations

enum Transfer {
    /// Joins remote dir + file name into a login-root-relative path.
    static func remotePath(_ dir: String, _ name: String) -> String {
        let d = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return d.isEmpty ? name : "\(d)/\(name)"
    }

    /// Non-secret curl flags. `-g` disables globbing so [ ] { } in local paths upload fine.
    /// `silent` adds `-s` (suppresses the progress meter) — the upload path sets it false so
    /// `--progress-bar` actually reaches stderr; other calls keep it on so the meter can't
    /// pollute captured stdout+stderr output.
    private static func curlBase(_ account: Account, silent: Bool = true) -> [String] {
        var args = silent ? ["-sS"] : ["-S"]
        args += ["--fail", "-g", "--connect-timeout", "\(account.timeoutSeconds)"]
        if account.type == .ftps { args += ["--ssl-reqd"] }
        return args
    }

    /// Escapes a value for a double-quoted curl `-K` config entry.
    static func curlQuote(_ s: String) -> String {
        "\"" + s.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    /// Basic-auth config line for curl `-K` stdin (keeps credentials out of argv / `ps`).
    static func basicAuthConfig(_ account: Account, password: String) -> String {
        "user = \(curlQuote("\(account.username):\(password)"))\n"
    }

    /// Runs curl with secrets (basic-auth or an auth header) passed via a `-K -` config on
    /// stdin instead of argv, which is world-readable through `ps` (CWE-214).
    @discardableResult
    private static func runCurl(_ args: [String], auth: String, runner: ProcessRunner,
                                onStderr: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await runner.run("/usr/bin/curl", ["-K", "-"] + args,
                             stdin: Data(auth.utf8), onStderr: onStderr)
    }

    private static func ftpURL(_ account: Account, path: String) -> String {
        let encoded = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "ftp://\(account.host):\(account.effectivePort)/\(encoded)"
    }

    private static func webdavBase(_ account: Account) -> String {
        var base = account.host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !base.contains("://") { base = "https://" + base }
        return base
    }

    private static func webdavURL(_ account: Account, name: String) -> String {
        var base = webdavBase(account)
        let dir = account.remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !dir.isEmpty { base += "/" + dir }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return base + "/" + encoded
    }

    /// Creates each segment of a remote directory chain via MKCOL. No `--fail`, so an
    /// already-existing collection (405/301) is a harmless no-op. `dirURL` maps a partial
    /// (login-root-relative) directory path to its full URL for the backend.
    private static func makeRemoteDirs(_ account: Account, password: String, runner: ProcessRunner,
                                       dirURL: (String) -> String) async throws {
        let parts = account.remoteDir.split(separator: "/").map(String.init)
        for i in parts.indices {
            let partial = parts[0...i].joined(separator: "/")
            try? await runCurl(["-sS", "-o", "/dev/null", "--connect-timeout", "\(account.timeoutSeconds)",
                                "-X", "MKCOL", dirURL(partial)],
                               auth: basicAuthConfig(account, password: password), runner: runner)
        }
    }

    // MARK: Upload

    static func upload(_ localURL: URL, as name: String, to account: Account, password: String,
                       runner: ProcessRunner, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Every backend except SFTP is one curl PUT; the switch picks URL + extra args + auth.
        let url: String
        var extra: [String] = []
        var auth = basicAuthConfig(account, password: password)

        switch account.type {
        case .ftp, .ftps:
            url = ftpURL(account, path: remotePath(account.remoteDir, name))
            extra = ["--ftp-create-dirs"]
        case .webdav:
            // Settings promises the directory is created if missing — honor it (RFC 4918 MKCOL)
            try await makeRemoteDirs(account, password: password, runner: runner,
                                     dirURL: { webdavBase(account) + "/" + $0 })
            url = webdavURL(account, name: name)
        case .nextcloud:
            try await makeRemoteDirs(account, password: password, runner: runner) {
                var partial = account; partial.remoteDir = $0; return NextcloudAPI.davURL(partial)
            }
            url = NextcloudAPI.davURL(account, name: name)
        case .dropbox:
            let token = try await DropboxAPI.accessToken(appKey: account.dropboxAppKey ?? "",
                                                         refreshToken: password)
            let arg = DropboxAPI.headerSafeJSON([
                "path": DropboxAPI.apiPath(dir: account.remoteDir, name: name),
                "mode": "overwrite", "autorename": false,
            ])
            url = "https://content.dropboxapi.com/2/files/upload"
            extra = ["-H", "Dropbox-API-Arg: \(arg)", "-H", "Content-Type: application/octet-stream"]
            auth = "header = \(curlQuote("Authorization: Bearer \(token)"))\n" // Bearer off argv
        case .sftp:
            // ponytail: sftp CLI gives no machine-readable progress; UI shows indeterminate
            let dir = account.remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            var batch = ""
            if !dir.isEmpty {
                for (i, _) in dir.split(separator: "/").enumerated() {
                    let partial = dir.split(separator: "/")[0...i].joined(separator: "/")
                    batch += "-mkdir \(try sftpQuote(partial))\n" // -mkdir ignores already-exists
                }
            }
            batch += "put -f \(try sftpQuote(localURL.path)) \(try sftpQuote(remotePath(account.remoteDir, name)))\n"
            try await runSFTP(batch: batch, account: account, password: password, runner: runner)
            return
        }

        try await runCurl(curlBase(account, silent: false) + extra +
                          ["--progress-bar", "-T", localURL.path, url],
                          auth: auth, runner: runner,
                          onStderr: { chunk in
                              if let pct = lastPercent(in: chunk) { progress(pct / 100) }
                          })
    }

    /// Share link from the provider's API (Dropbox / Nextcloud).
    static func shareLink(for name: String, account: Account, password: String) async throws -> String {
        switch account.type {
        case .dropbox:
            let token = try await DropboxAPI.accessToken(appKey: account.dropboxAppKey ?? "",
                                                         refreshToken: password)
            return try await DropboxAPI.shareLink(
                path: DropboxAPI.apiPath(dir: account.remoteDir, name: name), token: token)
        case .nextcloud:
            return try await NextcloudAPI.shareLink(for: name, account: account, password: password)
        default:
            throw TransferError(message: "\(account.type.rawValue) links are derived, not fetched")
        }
    }

    // MARK: Delete

    static func delete(fileName: String, from account: Account, password: String) async throws {
        let runner = ProcessRunner()
        let auth = basicAuthConfig(account, password: password)
        switch account.type {
        case .ftp, .ftps:
            let path = remotePath(account.remoteDir, fileName)
            // -Q runs DELE after login, before the (ignored) listing
            let dirURL = ftpURL(account, path: account.remoteDir.isEmpty ? "" : account.remoteDir + "/")
            try await runCurl(curlBase(account) + ["--list-only", "-Q", "DELE \(path)", dirURL],
                              auth: auth, runner: runner)
        case .webdav:
            try await runCurl(curlBase(account) +
                              ["-X", "DELETE", "-o", "/dev/null", webdavURL(account, name: fileName)],
                              auth: auth, runner: runner)
        case .nextcloud:
            try await runCurl(curlBase(account) +
                              ["-X", "DELETE", "-o", "/dev/null", NextcloudAPI.davURL(account, name: fileName)],
                              auth: auth, runner: runner)
        case .dropbox:
            let token = try await DropboxAPI.accessToken(appKey: account.dropboxAppKey ?? "",
                                                         refreshToken: password)
            _ = try await DropboxAPI.rpc("files/delete_v2",
                                         args: ["path": DropboxAPI.apiPath(dir: account.remoteDir, name: fileName)],
                                         token: token)
        case .sftp:
            try await runSFTP(batch: "rm \(try sftpQuote(remotePath(account.remoteDir, fileName)))\n",
                              account: account, password: password, runner: runner)
        }
    }

    // MARK: SFTP via CLI

    /// Quotes a path for an sftp batch line. sftp's tokenizer honors `\\` and `\"` inside
    /// double quotes; control characters can't be represented on a batch line, so reject them
    /// (a filename with a newline would otherwise inject arbitrary sftp/`!shell` commands).
    static func sftpQuote(_ s: String) throws -> String {
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw TransferError(message: "File name contains control characters SFTP can’t handle.")
        }
        return "\"" + s.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    @discardableResult
    private static func runSFTP(batch: String, account: Account, password: String,
                                runner: ProcessRunner) async throws -> String {
        let batchURL = Sendling.supportDir.appendingPathComponent("sftp-batch-\(UUID().uuidString).txt")
        try batch.write(to: batchURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: batchURL) }

        var args = ["-P", "\(account.effectivePort)",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=\(account.timeoutSeconds)",
                    "-b", batchURL.path]
        var env: [String: String] = [:]
        if password.isEmpty {
            args += ["-o", "BatchMode=yes"] // key auth only; fail fast instead of hanging
        } else {
            // SSH_ASKPASS trick: ssh runs our script to fetch the password (no tty needed)
            args += ["-o", "NumberOfPasswordPrompts=1"]
            env = ["SSH_ASKPASS": askpassScript().path,
                   "SSH_ASKPASS_REQUIRE": "force",
                   "DISPLAY": ":0",
                   "SENDLING_ASKPW": password]
        }
        args.append("\(account.username)@\(account.host)")
        return try await runner.run("/usr/bin/sftp", args, env: env)
    }

    private static func askpassScript() -> URL {
        let url = Sendling.supportDir.appendingPathComponent("askpass.sh")
        let contents = "#!/bin/sh\nprintf '%s' \"$SENDLING_ASKPW\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != contents {
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    /// Parses the last "NN.N%" from curl --progress-bar output.
    private static func lastPercent(in chunk: String) -> Double? {
        var result: Double?
        var current = ""
        for ch in chunk {
            if ch.isNumber || ch == "." {
                current.append(ch)
            } else if ch == "%", let v = Double(current) {
                result = v
                current = ""
            } else {
                current = ""
            }
        }
        return result
    }

    // MARK: Directory listing (Refresh)

    /// Lists the account's remote directory. FTP/FTPS via curl LIST, SFTP via `ls -l`.
    /// ponytail: parses Unix ls format only (covers pure-ftpd/proftpd/openssh);
    /// DOS-format FTP servers would need a second parser branch.
    static func list(account: Account, password: String) async throws -> [RemoteEntry] {
        let runner = ProcessRunner()
        let output: String
        switch account.type {
        case .ftp, .ftps:
            let dirURL = ftpURL(account, path: account.remoteDir) + "/"
            output = try await runCurl(curlBase(account) + [dirURL],
                                       auth: basicAuthConfig(account, password: password), runner: runner)
        case .sftp:
            let dir = account.remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            output = try await runSFTP(batch: "ls -l \(try sftpQuote(dir.isEmpty ? "." : dir))\n",
                                       account: account, password: password, runner: runner)
        case .nextcloud:
            return try await NextcloudAPI.list(account: account, password: password, runner: runner)
        case .dropbox:
            let token = try await DropboxAPI.accessToken(appKey: account.dropboxAppKey ?? "",
                                                         refreshToken: password)
            // ponytail: first page (~2000 entries); cursor pagination if a folder outgrows it
            let json = try await DropboxAPI.rpc("files/list_folder",
                                                args: ["path": DropboxAPI.apiPath(dir: account.remoteDir)],
                                                token: token)
            return DropboxAPI.parseEntries(json)
        case .webdav:
            throw TransferError(message: "Listing isn’t supported for WebDAV") // ponytail: PROPFIND if ever needed
        }

        let entries = parseUnixListing(output)
        let meaningfulLines = output.split(separator: "\n").filter {
            !$0.isEmpty && !$0.hasPrefix("total") && !$0.hasPrefix("sftp>")
        }
        if entries.isEmpty && !meaningfulLines.isEmpty {
            throw TransferError(message: "Couldn’t parse the server’s directory listing")
        }
        return entries
    }

    /// Parses `ls -l`-style listings: "-rw-r--r-- 1 user group 1024 Jul 8 13:00 name".
    static func parseUnixListing(_ text: String) -> [RemoteEntry] {
        let pattern = #/^(\S+)\s+\d+\s+\S+(?:\s+\S+)?\s+(\d+)\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s+(.+)$/#
        let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                      "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
        var entries: [RemoteEntry] = []

        for line in text.split(separator: "\n") {
            guard let match = line.wholeMatch(of: pattern) else { continue }
            // Only regular files become sent-file rows. Admitting directories/symlinks lets
            // Delete Expired issue a recursive server-side delete of a whole folder.
            guard match.1.first == "-" else { continue }

            let name = String(match.6)
            guard name != "." && name != ".." else { continue }

            var modified: Date?
            if let month = months[String(match.3)], let day = Int(String(match.4)) {
                var comps = DateComponents()
                comps.month = month
                comps.day = day
                let timeOrYear = String(match.5)
                if timeOrYear.contains(":") {
                    let parts = timeOrYear.split(separator: ":")
                    comps.year = Calendar.current.component(.year, from: .now)
                    comps.hour = Int(parts[0])
                    comps.minute = Int(parts[1])
                    if let d = Calendar.current.date(from: comps), d > Date.now.addingTimeInterval(86400) {
                        comps.year! -= 1 // "Jul 8 13:00" with no year means the most recent Jul 8
                    }
                } else {
                    comps.year = Int(timeOrYear)
                    comps.hour = 12
                }
                modified = Calendar.current.date(from: comps)
            }

            entries.append(RemoteEntry(name: name,
                                       size: Int64(String(match.2)) ?? 0,
                                       modified: modified))
        }
        return entries
    }

    // MARK: Existence check (WebDAV Refresh fallback)

    /// nil = unknown (server error / no URL), true/false = exists.
    static func exists(_ file: SentFile, account: Account) async -> Bool? {
        guard let url = account.downloadURL(for: file.name) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200...299: return true
        case 404, 410: return false
        default: return nil
        }
    }
}

// MARK: - Archiving

enum Archiver {
    static func randomString(_ length: Int = 6) -> String {
        let chars = "abcdefghjkmnpqrstuvwxyz23456789"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    static func archiveName(for sources: [URL], account: Account) -> String {
        let base = sources[0].deletingPathExtension().lastPathComponent
        switch account.archiveNaming {
        case .itemName: return base
        case .randomString: return randomString(10)
        case .itemNamePlusRandom: return "\(base)-\(randomString())"
        }
    }

    /// Stages sources into a temp dir (APFS clones, so cheap) and archives them.
    /// Returns the archive URL; caller cleans up the parent temp dir.
    static func archive(sources: [URL], name: String, type: ArchiveType,
                        password: String, excludeDSStore: Bool,
                        runner: ProcessRunner) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("sendling-\(UUID().uuidString)")
        let staging = work.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Stage each source under a unique basename so two items with the same name
        // (2023/report.pdf + 2024/report.pdf) don't collide and silently drop one.
        var used = Set<String>()
        for src in sources {
            let base = src.lastPathComponent
            var dest = base
            var n = 2
            while used.contains(dest) {
                let stem = (base as NSString).deletingPathExtension
                let ext = (base as NSString).pathExtension
                dest = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                n += 1
            }
            used.insert(dest)
            try await runner.run("/bin/cp", ["-cR", src.path, staging.appendingPathComponent(dest).path])
        }

        let archiveURL = work.appendingPathComponent("\(name).\(type.fileExtension)")
        // "./" prefix so item names beginning with "-" aren't parsed as options by zip/tar.
        let itemArgs = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .filter { !(excludeDSStore && $0 == ".DS_Store") }
            .map { "./\($0)" }

        switch type {
        case .zip:
            var args = ["-r", "-q"]
            // ponytail: zip -P leaks the password via ps and uses weak ZipCrypto; a stdin/AES
            // path needs a dependency or the DMG format. Use an encrypted DMG for real secrecy.
            if !password.isEmpty { args += ["-P", password] }
            args += [archiveURL.path] + itemArgs
            if excludeDSStore { args += ["-x", "*.DS_Store", "-x", "*/.DS_Store"] }
            try await runner.run("/usr/bin/zip", args, cwd: staging)
        case .targz:
            var args = ["-czf", archiveURL.path]
            if excludeDSStore { args += ["--exclude", ".DS_Store"] }
            args += itemArgs
            try await runner.run("/usr/bin/tar", args, cwd: staging)
        case .dmg:
            var args = ["create", "-quiet", "-fs", "APFS", "-volname", name,
                        "-srcfolder", staging.path, "-format", "UDZO"]
            if !password.isEmpty {
                args += ["-encryption", "AES-256", "-stdinpass"] // reads the password from stdin
            }
            args.append(archiveURL.path)
            try await runner.run("/usr/bin/hdiutil", args,
                                 stdin: password.isEmpty ? nil : Data(password.utf8))
        }
        return archiveURL
    }
}
