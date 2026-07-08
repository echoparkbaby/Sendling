import Testing
import Foundation
@testable import Sendling

struct TransferTests {
    @Test(arguments: [
        ("", "a.txt", "a.txt"),
        ("/files/", "a.txt", "files/a.txt"),
        ("public_html/drop", "b c.zip", "public_html/drop/b c.zip"),
    ])
    func remotePathJoining(dir: String, name: String, expected: String) {
        #expect(Transfer.remotePath(dir, name) == expected)
    }

    @Test func parsesUnixDirectoryListings() throws {
        let listing = """
        total 48
        -rw-r--r--    1 hellocomp hellocomp     1024 Jul  8 13:00 stfvkeys.txt
        -rw-r--r--    1 hellocomp hellocomp 19818086 Jul  1 09:12 lake-van.zip
        drwxr-xr-x    2 hellocomp hellocomp     4096 Jun  1 08:00 pkgs
        -rw-r--r--@   1 501       20         2190000 Jan 31  2026 elementaryos-8.1-stable-arm64.iso
        lrwxrwxrwx    1 hellocomp hellocomp       11 May  5 11:11 latest.zip -> lake-van.zip
        -rw-r--r--    1 hellocomp hellocomp      855 Dec 31  2025 PGM VDP 1 EVENT - WALLA WALLA
        sftp> ls -l filechute
        """
        let entries = Transfer.parseUnixListing(listing)
        // Files only — directories (pkgs) and symlinks (latest.zip) are excluded so that
        // Delete Expired can never recursively delete a remote folder.
        try #require(entries.count == 4)
        let names = entries.map(\.name)
        #expect(names == ["stfvkeys.txt", "lake-van.zip", "elementaryos-8.1-stable-arm64.iso",
                          "PGM VDP 1 EVENT - WALLA WALLA"])
        #expect(entries[0].size == 1024)
        #expect(names.contains("pkgs") == false, "directory rows must be dropped")
        #expect(names.contains("latest.zip") == false, "symlink rows must be dropped")
        let year = try #require(entries[2].modified.map { Calendar.current.component(.year, from: $0) })
        #expect(year == 2026)
    }
}

struct ArchiverTests {
    @Test func archiveNamingFollowsAccountSetting() {
        var account = Account()
        let sources = [URL(fileURLWithPath: "/tmp/Lake Van.afdesign")]
        account.archiveNaming = .itemName
        #expect(Archiver.archiveName(for: sources, account: account) == "Lake Van")
        account.archiveNaming = .itemNamePlusRandom
        let name = Archiver.archiveName(for: sources, account: account)
        #expect(name.hasPrefix("Lake Van-"))
        #expect(name.count == "Lake Van-".count + 6)
    }

    @Test func zipArchiveStagesAndExcludesDSStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = dir.appendingPathComponent("Stuff")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let zip = try await Archiver.archive(sources: [folder], name: "Stuff", type: .zip,
                                             password: "", excludeDSStore: true, runner: ProcessRunner())
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "zipinfo should read the archive")
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(listing.contains("Stuff/a.txt"))
        #expect(listing.contains(".DS_Store") == false)
    }
}

struct AccountTests {
    @Test func suggestedDownloadURLHeuristics() {
        var account = Account()
        account.host = "ftp.raydelltubbs.com"
        account.remoteDir = "public_html/files"
        #expect(account.suggestedDownloadURL == "https://raydelltubbs.com/files")
        account.remoteDir = "filechute"
        #expect(account.suggestedDownloadURL == "https://raydelltubbs.com/filechute")
        account.host = "https://dav.example.com"
        account.remoteDir = "public_html"
        #expect(account.suggestedDownloadURL == "https://dav.example.com")
    }

    @Test func downloadURLEncodesNames() {
        var account = Account()
        account.downloadURLBase = "https://example.com/files/"
        #expect(account.downloadURL(for: "b c.zip")?.absoluteString == "https://example.com/files/b%20c.zip")
        account.downloadURLBase = ""
        #expect(account.downloadURL(for: "x") == nil)
    }

    @Test func apiShareLinkOverridesDerivedURL() {
        var account = Account()
        account.downloadURLBase = "https://example.com/files"
        var file = SentFile(accountID: account.id, name: "a.zip", size: 1, sentDate: .now)
        file.link = "https://cloud.example.com/s/AbCdEf"
        #expect(account.downloadURL(for: file)?.absoluteString == "https://cloud.example.com/s/AbCdEf")
    }
}

struct DropboxAPITests {
    @Test func parsesEntriesFilesOnly() throws {
        let json: [String: Any] = ["entries": [
            [".tag": "file", "name": "lake-van.zip", "size": 19818086, "server_modified": "2026-07-01T09:12:00Z"],
            [".tag": "folder", "name": "pkgs"],
        ]]
        let entries = DropboxAPI.parseEntries(json)
        // The folder must be dropped so it can't become a recursively-deletable sent-file row.
        try #require(entries.count == 1)
        #expect(entries[0].name == "lake-van.zip")
        #expect(entries[0].size == 19818086)
        #expect(entries[0].modified != nil)
    }

    @Test func headerJSONEscapesNonASCII() {
        let arg = DropboxAPI.headerSafeJSON(["path": "/tëst/💾.zip"])
        #expect(arg.contains("ë") == false)
        #expect(arg.contains("\\u00eb"))
        #expect(arg.contains("\\ud83d\\udcbe"), "💾 should be escaped as a surrogate pair")
    }
}

struct NextcloudAPITests {
    @Test func parsesPropfindFilesOnly() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:"><d:response>
        <d:href>/remote.php/dav/files/brandon/Sendling/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
        </d:response><d:response>
        <d:href>/remote.php/dav/files/brandon/Sendling/archive/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
        </d:response><d:response>
        <d:href>/remote.php/dav/files/brandon/Sendling/lake%20van.zip</d:href>
        <d:propstat><d:prop>
        <d:getlastmodified>Tue, 07 Jul 2026 10:00:00 GMT</d:getlastmodified>
        <d:getcontentlength>12345</d:getcontentlength>
        <d:resourcetype/>
        </d:prop></d:propstat>
        </d:response></d:multistatus>
        """
        let entries = NextcloudAPI.parsePropfind(xml)
        // The nested "archive/" collection must be skipped, not shared/deleted as a file.
        try #require(entries.count == 1)
        #expect(entries[0].name == "lake van.zip")
        #expect(entries[0].size == 12345)
        #expect(entries[0].modified != nil)
    }
}

struct SecurityAndExpiryTests {
    @Test func sftpQuoteEscapesAndRejectsControlChars() throws {
        #expect(try Transfer.sftpQuote("plain.zip") == "\"plain.zip\"")
        #expect(try Transfer.sftpQuote(#"a"b\c.zip"#) == #""a\"b\\c.zip""#)
        // A newline could inject an sftp/!shell command — must be rejected.
        #expect(throws: TransferError.self) { try Transfer.sftpQuote("evil\nrm x") }
    }

    @Test func curlConfigQuoteEscapes() {
        // Credentials go into a -K config value; quotes/backslashes must be escaped.
        #expect(Transfer.curlQuote(#"user:p"w\d"#) == #""user:p\"w\\d""#)
    }

    @Test(arguments: [
        (7, 6, false), (7, 7, true), (7, 8, true), (0, 999, false),
    ])
    func expiryIsInclusive(expireDays: Int, ageDays: Int, expected: Bool) {
        var account = Account()
        account.expireDays = expireDays
        let uploaded = Calendar.current.date(byAdding: .day, value: -ageDays, to: .now)!
        let file = SentFile(accountID: account.id, name: "x", size: 1, sentDate: uploaded)
        #expect(file.isExpired(in: account) == expected)
    }
}
