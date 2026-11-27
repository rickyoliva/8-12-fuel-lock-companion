import SwiftUI

/// Displays live on-device self-pairing progress, step-by-step Settings
/// instructions, and the 6-digit PIN banner while the user approves pairing.
struct SelfPairingStatusCard: View {
    @EnvironmentObject private var spoofManager: LocationSpoofManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(spoofManager.pairingState.statusText)
                    .font(.subheadline.weight(.semibold))
            }

            if let pin = spoofManager.pairingPIN {
                VStack(spacing: 6) {
                    Text("PAIRING PIN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .tracking(4)
                        .textSelection(.enabled)
                    Text("Enter this 6-digit code in Settings › Privacy & Security › Developer Mode › Pair with 8/12 Fuel Lock. A notification will also keep it visible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("1. Open Settings › Privacy & Security › Developer Mode.\n2. Tap Pair with 8/12 Fuel Lock.\n3. Enter the 6-digit PIN that appears here and in your notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Cancel", role: .destructive) {
                    spoofManager.cancelSelfPairing()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
