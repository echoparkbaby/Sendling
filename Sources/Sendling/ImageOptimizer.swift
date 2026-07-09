import Foundation

/// Per-send image-compression override (from the ⌥-drop options sheet).
struct ImageOptSetting: Equatable {
    var enabled: Bool
    var maxDim: Int
}

/// Optionally downscales/recompresses a large image before upload, via macOS `sips` (no deps).
/// Returns a temp copy only when it's actually smaller than the original; else nil (send original).
enum ImageOptimizer {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "optimizeImages") }
    static var maxDimension: Int {
        let v = UserDefaults.standard.integer(forKey: "optimizeImagesMaxDim")
        return v == 0 ? 2048 : v // default longest-side cap
    }

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "gif"]

    static func isImage(_ url: URL) -> Bool { imageExts.contains(url.pathExtension.lowercased()) }

    /// `override` (from the per-send options sheet) wins over the global Settings toggle.
    static func optimizedIfNeeded(_ url: URL, override: ImageOptSetting? = nil) async -> URL? {
        let enabled = override?.enabled ?? isEnabled
        let maxDim = override?.maxDim ?? maxDimension
        guard enabled, isImage(url) else { return nil }
        let originalSize = fileSize(url)
        guard originalSize > 300_000 else { return nil } // not worth it for small images

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sendling-opt-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        let dest = dir.appendingPathComponent(url.lastPathComponent) // keep the same filename/ext

        var args = ["-Z", "\(maxDim)"] // resample longest side; only ever downsizes
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" { args += ["-s", "formatOptions", "80"] } // recompress
        args += [url.path, "--out", dest.path]

        guard (try? await ProcessRunner().run("/usr/bin/sips", args)) != nil else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        // Only use it if we actually saved bytes (recompression can grow an already-tiny image).
        if fileSize(dest) < originalSize, fileSize(dest) > 0 { return dest }
        try? FileManager.default.removeItem(at: dir)
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
