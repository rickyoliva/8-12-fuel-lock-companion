import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var spoofManager: LocationSpoofManager
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var state = OnboardingState()
    @State private var showingFileImporter = false

    let isReopenedFromSettings: Bool
    let onComplete: () -> Void

    init(isReopenedFromSettings: Bool = false, onComplete: @escaping () -> Void) {
        self.isReopenedFromSettings = isReopenedFromSettings
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerView

                    stepCard(
                        step: .localDevVPN,
                        subtitle: vpnSubtitle,
                        isComplete: state.isStepComplete(.localDevVPN, vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: spoofManager.pairingFileExists),
                        isSkipped: state.isStepSkipped(.localDevVPN, vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: spoofManager.pairingFileExists)
                    ) {
                        localDevVPNContent
                    }

                    stepCard(
                        step: .pairingFile,
                        subtitle: pairingSubtitle,
                        isComplete: state.isStepComplete(.pairingFile, vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: spoofManager.pairingFileExists),
                        isSkipped: state.isStepSkipped(.pairingFile, vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: spoofManager.pairingFileExists)
                    ) {
                        pairingFileContent
                    }

                    stepCard(
                        step: .disclaimer,
                        subtitle: state.disclaimerAcknowledged ? "Acknowledged" : "Read and accept before continuing",
                        isComplete: state.disclaimerAcknowledged,
                        isSkipped: false
                    ) {
                        disclaimerContent
                    }

                    continueSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isReopenedFromSettings ? "Setup & Disclaimer" : "Welcome to 8/12")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isReopenedFromSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { onComplete() }
                    }
                }
            }
            .task {
                spoofManager.refreshState()
                state.advance(vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: spoofManager.pairingFileExists)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    spoofManager.refreshState()
                    if spoofManager.isLocalDevVPNDetected && state.expandedStep == .localDevVPN {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            state.advance(vpnDetected: true, pairingExists: spoofManager.pairingFileExists)
                        }
                    }
                }
            }
            .onChange(of: spoofManager.pairingFileExists) { _, exists in
                if exists && state.expandedStep == .pairingFile {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        state.advance(vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: true)
                    }
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
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Setup")
                .font(.title2.weight(.bold))
            Text("Complete these steps to simulate GPS locations for 7-Eleven Fuel Lock on iOS 26.4+.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Collapsible Step Container

    private func stepCard<Content: View>(
        step: OnboardingState.Step,
        subtitle: String,
        isComplete: Bool,
        isSkipped: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isExpanded = state.expandedStep == step

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    state.expandedStep = step
                }
            } label: {
                HStack(spacing: 12) {
                    statusBadge(number: step.number, isComplete: isComplete, isSkipped: isSkipped)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isSkipped ? .orange : .secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                content()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusBadge(number: Int, isComplete: Bool, isSkipped: Bool) -> some View {
        Group {
            if isSkipped {
                Image(systemName: "forward.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            } else if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())
            }
        }
    }

    // MARK: - Step 1: LocalDevVPN

    private var vpnSubtitle: String {
        if spoofManager.vpnConnected {
            return "Tunnel active"
        } else if spoofManager.localDevVPNInstalled || state.vpnConfirmed {
            return "Installed — ready"
        } else if state.vpnSkipped {
            return "Skipped (can configure later)"
        }
        return "Required for on-device GPS simulation"
    }

    private var localDevVPNContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if spoofManager.isLocalDevVPNDetected || state.vpnConfirmed {
                Label(
                    spoofManager.vpnConnected ? "LocalDevVPN tunnel is active." : "LocalDevVPN is installed on this device.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)

                Button("Continue to Step 2") {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        state.confirmVPN()
                        state.advance(vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: spoofManager.pairingFileExists)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("8/12 requires LocalDevVPN to open a local developer tunnel on iOS 26.4+. LocalDevVPN was not detected on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Button {
                        if let url = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044") {
                            openURL(url)
                        }
                    } label: {
                        Label("Install LocalDevVPN (App Store)", systemImage: "arrow.down.app.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if let url = URL(string: "https://github.com/jkcoxson/LocalDevVPN") {
                            openURL(url)
                        }
                    } label: {
                        Label("View LocalDevVPN on GitHub", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Button("Recheck") {
                        spoofManager.refreshState()
                        if spoofManager.isLocalDevVPNDetected {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                state.advance(vpnDetected: true, pairingExists: spoofManager.pairingFileExists)
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("I have it") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            state.confirmVPN()
                            state.advance(vpnDetected: true, pairingExists: spoofManager.pairingFileExists)
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Skip") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            state.skipVPN()
                            state.advance(vpnDetected: false, pairingExists: spoofManager.pairingFileExists)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 2: Pairing File

    private var pairingSubtitle: String {
        if spoofManager.pairingFileExists {
            return "Imported (\(PairingFileStore.standardFilename))"
        } else if state.pairingSkipped {
            return "Skipped (can import later in Settings)"
        }
        return "Import .plist or .mobiledevicepairing"
    }

    private var pairingFileContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if spoofManager.pairingFileExists {
                Label("Pairing file is imported and saved.", systemImage: "doc.badge.checkmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)

                if let kind = spoofManager.pairingFileKind, !kind.hasRemotePairing {
                    Text("Warning: This looks like a classic lockdown pairing file. iOS 26.4+ requires a Remote Pairing file.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Replace File") {
                        showingFileImporter = true
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Continue to Step 3") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            state.advance(vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Import your Remote Pairing file from SideInstaller, iLoader, or idevice_pair.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Tip: You can also use SideInstaller's \"Export pairing file\" → Share Sheet → \"Open in 8/12 Fuel Lock\", or drop pairingFile.plist into the Files app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let err = spoofManager.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Import Pairing File", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Button("Skip for now") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            state.skipPairing()
                            state.advance(vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: false)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 3: Disclaimer

    private var disclaimerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account Ban & Risk Warning")
                        .font(.subheadline.weight(.bold))
                    Text("7-Eleven actively monitors and bans accounts suspected of interstate Fuel Lock abuse or GPS location spoofing. Using 8/12 may violate 7-Eleven's Terms of Service and result in permanent account suspension or forfeited locked vouchers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("You use this app entirely at your own risk.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    state.acknowledgeDisclaimer()
                    state.advance(vpnDetected: spoofManager.isLocalDevVPNDetected, pairingExists: spoofManager.pairingFileExists)
                }
            } label: {
                HStack {
                    Image(systemName: state.disclaimerAcknowledged ? "checkmark.square.fill" : "square")
                    Text("I understand the risks and use 8/12 at my own risk")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(state.disclaimerAcknowledged ? .green : .accentColor)
        }
    }

    // MARK: - Step 4: Continue to App

    private var continueSection: some View {
        VStack(spacing: 8) {
            Button {
                onComplete()
            } label: {
                Text("Continue to app")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.canContinueToApp)

            if !state.canContinueToApp {
                Text("Please acknowledge the risk disclaimer above to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}
