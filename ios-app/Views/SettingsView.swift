import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var spoofManager: LocationSpoofManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingFileImporter = false
    @State private var showingDeleteConfirm = false
    @State private var showingOnboarding = false
    @State private var copiedLogs = false

    var body: some View {
        NavigationStack {
            Form {
                localDevVPNSection
                pairingFileSection
                diagnosticLogsSection
                onboardingSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: PairingFileStore.supportedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        spoofManager.importPairingFile(from: url)
                    }
                case .failure(let error):
                    spoofManager.errorMessage = "File import failed: \(error.localizedDescription)"
                }
            }
            .alert("Remove Pairing File?", isPresented: $showingDeleteConfirm) {
                Button("Remove", role: .destructive) {
                    spoofManager.removePairingFile()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete \(PairingFileStore.standardFilename) from 8/12. You'll need to import a pairing file again before spoofing.")
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView(isReopenedFromSettings: true) {
                    showingOnboarding = false
                }
                .environmentObject(spoofManager)
            }
        }
    }

    // MARK: - LocalDevVPN Config

    private var localDevVPNSection: some View {
        Section {
            HStack {
                Label("Tunnel Status", systemImage: spoofManager.vpnConnected ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(spoofManager.vpnConnected ? .green : .secondary)
                Spacer()
                Text(spoofManager.vpnConnected ? "Connected" : "Not Connected")
                    .font(.subheadline)
                    .foregroundStyle(spoofManager.vpnConnected ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Endpoint")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("10.7.0.1/32 or host:port", text: $spoofManager.deviceIP)
                        .font(.subheadline.monospaced())
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !spoofManager.isDeviceEndpointValid {
                    Text("Enter an IP, CIDR, or host:port (e.g. 10.7.0.1/32 or 10.7.0.1:49152).")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let endpoint = spoofManager.resolvedEndpoint {
                    Text("Resolved: \(endpoint.host):\(endpoint.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Open LocalDevVPN") {
                    spoofManager.openLocalDevVPN()
                }
                Spacer()
                Button("Refresh") {
                    spoofManager.refreshState()
                }
            }
        } header: {
            Text("LocalDevVPN")
        } footer: {
            Text("Default is 10.7.0.1/32 (port 49152). Customize only if your LocalDevVPN profile uses a different address or port.")
        }
    }

    // MARK: - Pairing File Config

    private var pairingFileSection: some View {
        Section {
            HStack {
                Label("Status", systemImage: pairingStatusIcon)
                    .foregroundStyle(pairingStatusColor)
                Spacer()
                Text(pairingStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                showingFileImporter = true
            } label: {
                Label(spoofManager.pairingFileExists ? "Replace Pairing File" : "Import Pairing File", systemImage: "doc.badge.plus")
            }

            if spoofManager.pairingFileExists {
                ShareLink(item: LocationSpoofManager.pairingFileURL) {
                    Label("Export / Share Pairing File", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Pairing File", systemImage: "trash")
                }
            }
        } header: {
            Text("Pairing File")
        } footer: {
            Text("Stored at Documents/\(PairingFileStore.standardFilename). You can also share a .plist or .mobiledevicepairing file into 8/12 via the Share Sheet or Files app.")
        }
    }

    private var pairingStatusIcon: String {
        guard spoofManager.pairingFileExists else { return "doc" }
        return spoofManager.pairingFileKind?.hasRemotePairing == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var pairingStatusColor: Color {
        guard spoofManager.pairingFileExists else { return .secondary }
        return spoofManager.pairingFileKind?.hasRemotePairing == true ? .green : .orange
    }

    private var pairingStatusText: String {
        guard spoofManager.pairingFileExists else { return "Not Imported" }
        if spoofManager.pairingFileKind?.hasRemotePairing == true {
            return "Remote Pairing Ready"
        }
        return "Classic Lockdown (Needs Remote)"
    }

    // MARK: - Diagnostic Logs

    private var diagnosticLogsSection: some View {
        Section {
            if spoofManager.logs.isEmpty {
                Text("No diagnostic logs yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(spoofManager.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 140, maxHeight: 240)
            }

            HStack {
                Button {
                    UIPasteboard.general.string = spoofManager.formattedLogs
                    copiedLogs = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedLogs = false
                    }
                } label: {
                    Label(copiedLogs ? "Copied" : "Copy Logs", systemImage: copiedLogs ? "checkmark" : "doc.on.doc")
                }
                .disabled(spoofManager.logs.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    spoofManager.clearLogs()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(spoofManager.logs.isEmpty)
            }
        } header: {
            Text("Diagnostic Logs")
        }
    }

    // MARK: - Onboarding & Disclaimer

    private var onboardingSection: some View {
        Section {
            Button {
                showingOnboarding = true
            } label: {
                Label("Re-open Onboarding & Disclaimer", systemImage: "checklist")
            }
        } header: {
            Text("Help & Legal")
        }
    }
}
