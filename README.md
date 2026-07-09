# Sendling

**Drop a file. Get a link.**

Sendling is a native macOS app that uploads files to *your own* server (SFTP, FTP, FTPS, or WebDAV) and puts a shareable download link on your clipboard. No third-party cloud, no accounts, no subscription — your server, your files, your links.

It's a modern, open-source successor to the late, great [FileChute](https://yellowmug.com/filechute/), rebuilt from scratch in Swift and SwiftUI.

![Sendling main window](docs/screenshot.png)

## Features

- **Two drop wells** — drop on **Send** to upload as-is, or on **Compress** to zip everything into one archive first. Dropping anywhere else on the window (or the Dock icon, or ⌘O) does a normal send.
- **Your server, your rules** — SFTP (password or SSH key), FTP, FTPS, WebDAV, Nextcloud, and Dropbox
- **Real share links** — Nextcloud accounts get `/s/…` links via the OCS API; Dropbox accounts get proper share links (one-time OAuth setup with your own app key)
- **Protected & expiring links** — set a per-account link password and auto-expiry (Nextcloud; Dropbox needs a paid plan)
- **Finder integration** — right-click any file → Services → **Send with Sendling** (or **Compress & Send**), no need to open the app
- **Watched folder** — point Sendling at a folder and anything dropped in uploads automatically
- **Test Connection** — verify a server's host, credentials, and directory before you rely on it
- **Send options** — hold **⌥ Option** while dropping (or clicking a well) to set a one-off remote filename, archive choice, and link password/expiry for that send
- **Optimize images** — optionally downscale/recompress large images before upload
- **Automate it** — `sendling://send?path=/file&compress=1` works from Shortcuts (Open URL), Automator, or `open`
- **In-app updates** — checks GitHub and can download + install the new version in place
- **Copy as Markdown / HTML**, retry failed uploads, and more
- **Instant links** — download URL copied to your clipboard the moment the upload finishes
- **Archives on the fly** — wrap files/folders as `zip`, `tar.gz`, or `dmg`, optionally password-protected, with `.DS_Store` excluded
- **Smart naming** — archive names from the item name, a random string (harder to guess on your server), or both
- **Sent-file history** — sortable table with name, size, send date, and age; filter with the search field
- **Expiry** — set per-account expiry in days, see ages tick up (orange → red), and delete expired files from the server with ⌘D or automatically at launch
- **Refresh** — loads the server's real directory listing: files uploaded from anywhere appear, sizes sync, and vanished files get flagged (WebDAV verifies via HEAD instead)
- **QR codes** — show a scannable code for any link, perfect for handing a file to a phone
- **Menu bar extra** — recent links one click away, send files without the main window
- **Multiple accounts** — switch with ⌘1–⌘9
- **Per-file actions** — copy link, open in browser, compose email, delete from server (right-click or the Links menu)
- **Quick delete** — the `×` on each row deletes that file from the server after a confirmation; hold **⌘ Command** while clicking (or press **⌘⌫**) to skip the confirmation and delete immediately
- **iCloud sync** — turn on in Settings to sync accounts and history across your Macs via iCloud Drive (passwords stay on each Mac)
- **Native notifications** and optional completion sounds
- **FileChute migration** — one-click account import if FileChute's preferences are found
- **Universal binary** (Apple silicon + Intel), signed with a Developer ID

## Install

Grab the latest `Sendling.app` from [Releases](https://github.com/echoparkbaby/Sendling/releases), unzip, and drag it into `/Applications`.

Requires macOS 14 (Sonoma) or later.

## Setup

1. Open **Settings… (⌘,) → Accounts** and add an account.
2. Fill in the server details and the **Download URL** — the public web address where uploaded files become reachable (e.g. your server's `~/public_html/files` might be `https://example.com/files`).
3. Drop a file on the window. The link is on your clipboard.

For SFTP, leave the password empty to authenticate with your SSH keys.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| **⌘O** | Choose files to send |
| **⌘,** | Open Settings |
| **⌘1**–**⌘9** | Switch account |
| **⌘⇧C** | Copy the selected file's link |
| **⌘⇧O** | Open the link in your browser |
| **⌘⇧E** | Compose an email with the link |
| **⌫** | Delete the selected file (asks first) |
| **⌘⌫** | Delete the selected file — no confirmation |
| **⌘D** | Delete expired files |
| Double-click a row | Copy that file's link |
| **⌥**-drag onto a well | Open per-send options (rename, compress an image, link expiry) |
| **⌘**-click the **×** | Delete that file without confirmation |

## Build from source

```
git clone https://github.com/echoparkbaby/Sendling.git
cd Sendling
./build.sh "-"
```

`./build.sh` produces a signed universal `build/Sendling.app`. Pass your own signing identity as the first argument, or `"-"` for ad-hoc signing. Plain `swift build` works for development.

There are no dependencies — the transfer layer is `curl` and `sftp`, the archive layer is `zip`, `tar`, and `hdiutil`, all shipped with macOS.

## Support

If Sendling saves you a subscription, you can buy me a coffee:

<a href="https://buymeacoffee.com/echoparkbaby"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="50"></a>

## License

MIT — see [LICENSE](LICENSE).
