import SwiftUI

/// First-launch welcome. Offers to turn on iCloud sync, and if another Mac has already
/// synced Sendling data into iCloud, offers to adopt it here.
struct WelcomeSheet: View {
    let iCloudAvailable: Bool
    let iCloudHasData: Bool
    var onEnableSync: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let iconGradient = LinearGradient(
        colors: [Color(red: 0.28, green: 0.20, blue: 0.85),
                 Color(red: 0.12, green: 0.55, blue: 0.96)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(iconGradient)

            VStack(spacing: 4) {
                Text("Welcome to Sendling").font(.title2.bold())
                Text("Drop a file, get a shareable link.")
                    .foregroundStyle(.secondary)
            }

            if iCloudAvailable {
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: iCloudHasData ? "icloud.and.arrow.down" : "icloud")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(iCloudHasData ? "Sendling data found in iCloud" : "Sync across your Macs")
                                .font(.headline)
                            Text(iCloudHasData
                                 ? "Accounts you set up on another Mac are in your iCloud. Turn on sync to use them here."
                                 : "Keep your accounts and sent-file history in sync on all your Macs through iCloud Drive.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Passwords stay on each Mac — you’ll enter them once here.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                }

                Button(iCloudHasData ? "Turn On Sync & Load My Accounts" : "Turn On iCloud Sync") {
                    onEnableSync()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Not Now") { dismiss() }
                    .buttonStyle(.link)
            } else {
                Text("Tip: turn on iCloud Drive in System Settings to sync your accounts across your Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Get Started") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 420)
    }
}
