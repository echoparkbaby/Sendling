import AppKit
import SwiftUI

/// Floating upload-completion notice in the top-right corner (Growl, reborn).
/// One reusable panel; a new toast replaces the previous one. Click opens the link.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(fileName: String, url: URL?, error: String? = nil, copied: Bool) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: ToastView(
            fileName: fileName, url: url, error: error, copied: copied, onTap: { dismiss() }))
        hosting.frame.size = hosting.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // the SwiftUI view draws its own
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - hosting.fittingSize.width - 8,
                                     y: f.maxY - hosting.fittingSize.height - 8))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { dismiss() }
        }
    }

    static func dismiss() {
        dismissTask?.cancel()
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

private struct ToastView: View {
    let fileName: String
    let url: URL?
    let error: String?
    let copied: Bool
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(error == nil ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(error == nil ? "Uploaded — \(fileName)" : "Failed — \(fileName)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(error ?? (copied ? "Link copied to clipboard" : url?.absoluteString ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(14) // breathing room for the shadow inside the borderless panel
        .onTapGesture {
            if let url { NSWorkspace.shared.open(url) }
            onTap()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(error == nil ? "Uploaded \(fileName), open link" : "Upload failed for \(fileName)")
    }
}
