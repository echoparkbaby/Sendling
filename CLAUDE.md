# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `swift build` — dev build (SPM, no Xcode project)
- `./build.sh` — release: universal binary → `build/Sendling.app`, signed with "Developer ID Application: Brandon Walter (AQ5XNNSVN7)"; pass another identity or `"-"` (ad-hoc) as `$1`
- `swift scripts/make_icon.swift` — regenerate `Resources/AppIcon.icns` (only needed if the icon design changes)
- No tests, no lint config. Verify by building and launching `build/Sendling.app`.

## Architecture

SwiftUI menu-bar + window app (macOS 14+, Swift 6 toolchain in v5 language mode — see `Package.swift`). Zero package dependencies by design: all protocol/archive work shells out to macOS-bundled tools.

- **Transfer.swift** — the protocol layer is subprocesses: FTP/FTPS/WebDAV/Nextcloud via `/usr/bin/curl` (progress parsed from `--progress-bar` stderr), SFTP via `/usr/bin/sftp` batch files (password auth uses the `SSH_ASKPASS_REQUIRE=force` trick with a script in Application Support; no progress reporting). Archives via `zip`/`tar`/`hdiutil` after staging sources into a temp dir with `cp -cR` (APFS clones). Refresh fetches the real remote listing (curl FTP LIST / sftp `ls -l`, parsed by `parseUnixListing` — Unix format only) and `Store.reconcile` merges it: updates sizes, flags vanished files, adds files uploaded from elsewhere. WebDAV has no listing and falls back to per-file HEAD checks against the download URL.
- **DropboxAPI.swift / NextcloudAPI.swift** — API-link providers (`AccountType.linksFromAPI`): share links are fetched per file after upload and stored on `SentFile.link` (which `Account.downloadURL(for:)` prefers over the derived base URL). Dropbox: OAuth PKCE with pasted code, refresh token stored as the account "password" in Keychain, uploads via curl to the content API. Nextcloud: WebDAV endpoint (`remote.php/dav/files/<user>`) for transfer + OCS `files_sharing` API for links; listing via PROPFIND parsed with regex (`parsePropfind`).
- **UploadManager.swift** — serial upload queue (`pump()`), wrap-policy decisions (file/folder/multiple → send raw, archive, or present `AskSheet`), batch completion side effects (clipboard copy, notification, sound). Singleton, `@MainActor`.
- **Store.swift** — accounts + sent-file history persisted as JSON (`~/Library/Application Support/Sendling/data.json`, ISO-8601 dates on both encoder *and* decoder); passwords live only in the Keychain keyed by account UUID. Singleton, `@MainActor`.
- **SendlingApp.swift** — Window + Settings + MenuBarExtra scenes, all menu commands (⌘1–9 account switching, Links menu, Delete Expired ⌘D), AppDelegate for Dock-icon drops (`application(_:open:)`, enabled by `CFBundleDocumentTypes` in `Resources/Info.plist`).

Account model quirk: for WebDAV the `host` field holds the full base URL; for FTP/SFTP `remoteDir` is relative to the login root. Download links are always `downloadURLBase + "/" + percent-encoded name`.

The app bundle is assembled by hand in `build.sh` (no xcodeproj) — `Info.plist` changes must be made in `Resources/Info.plist`. Notifications require running from the signed `.app` bundle, not `swift run`.
