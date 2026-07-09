**Sendling 1.0.4**

Bug-fix release.

- **Dock drops / opening files work again** — a regression stopped Sendling from receiving files dragged onto its Dock icon (or opened with it). The Dock icon now accepts any file or folder and transfers it immediately.
- **Dropbox uploads fixed** — uploads were failing (504) because the request used the wrong HTTP method; they now upload correctly. Dropbox errors are also shown clearly (e.g. a missing permission), instead of a generic failure, and the setup hint lists the exact permissions to enable.
- **Files-and-folders access** — added the usage descriptions macOS shows when you point a Watched Folder at your Desktop, Documents, or Downloads.

Download `Sendling-v1.0.4.dmg`, open it, drag Sendling to Applications. Requires macOS 14 (Sonoma) or later. Universal (Apple silicon + Intel), signed and notarized. Zero dependencies.
