**Sendling 1.0.2**

New since 1.0.1:

- **Two drop wells** — **Send** (as-is) and **Compress** (zip into one archive first).
- **Send options** — hold **⌥ Option** while dropping (or clicking a well) to open a per-send sheet: rename the file on the server, compress an image (with a max-size choice), pick as-is vs archive, and set a link expiry — just for that send.
- **Image optimization** — optionally downscale/recompress large images before upload (Settings, or per-send).
- **Automation** — a `sendling://send?path=/file&compress=1` URL scheme callable from Shortcuts (Open URL), Automator, or `open`.
- **In-app updates** — checks GitHub at launch and can download + install the new version in place.
- **Quick delete** — hold **⌘ Command** (⌘-click the `×` or press ⌘⌫) to delete from the server without a confirmation.
- **"Compressing…"** indicator in the bottom bar while an archive is being built.

Download `Sendling-v1.0.2.dmg`, open it, drag Sendling to Applications. Requires macOS 14 (Sonoma) or later. Universal (Apple silicon + Intel), signed and notarized. Zero dependencies.
