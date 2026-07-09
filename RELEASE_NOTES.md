**Sendling 1.0.1**

New since 1.0:

- **iCloud sync** — turn it on in Settings to keep your accounts and sent-file history in sync across your Macs through iCloud Drive. Passwords stay on each Mac (entered once per machine).
- **First-launch welcome** — a fresh Mac offers to turn on sync, and if another Mac already synced Sendling data to iCloud, it offers to load those accounts here.
- **Inline delete** — every file row has an `×` that deletes it from the server after a confirmation. Hold **⌥ Option** (on the `×` or ⌫) to skip the confirmation and delete immediately.
- **QR sharing** — drag the QR code straight out to iMessage, Finder, or Mail as a picture, or use the new Share button.

Download `Sendling-v1.0.1.dmg`, open it, drag Sendling to Applications. Requires macOS 14 (Sonoma) or later. Universal (Apple silicon + Intel), signed and notarized.

Zero dependencies — transfers use `curl`/`sftp`, archives use `zip`/`tar`/`hdiutil`, all shipped with macOS.
