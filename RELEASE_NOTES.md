**Sendling 1.0** — drop a file, get a shareable link.

A native macOS app that uploads to *your own* server and puts the download link on your clipboard. No third-party cloud, no accounts, no subscription. Open-source successor to the late FileChute.

### Features
- **Six backends** — SFTP (password or SSH key), FTP, FTPS, WebDAV, Nextcloud, Dropbox
- **Real share links** — Nextcloud `/s/…` via the OCS API, Dropbox via its sharing API; other backends derive links from your download URL
- **Drag & drop** anywhere — the window's drop well, the Dock icon, or ⌘O
- **Archives on the fly** — wrap files/folders as zip, tar.gz, or dmg, optionally password-protected
- **Expiry** — per-account, with age badges and one-click / at-launch cleanup of expired files
- **Refresh** pulls the server's real directory listing
- **QR codes**, **menu bar extra** with recent links, **multiple accounts** (⌘1–9)
- **FileChute import** — brings your old accounts across

### Install
Download `Sendling-v1.0.0.dmg`, open it, drag Sendling to Applications. Requires macOS 14 (Sonoma) or later. Universal (Apple silicon + Intel), signed and notarized.

### Setup
Add a server account in Settings (⌘,), set the Download URL, then drop a file. The link is on your clipboard.

Zero dependencies — transfers use `curl`/`sftp`, archives use `zip`/`tar`/`hdiutil`, all shipped with macOS.
