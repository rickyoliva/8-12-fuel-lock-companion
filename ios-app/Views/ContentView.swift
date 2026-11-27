import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var fuelService: FuelPriceService
    @EnvironmentObject private var spoofManager: LocationSpoofManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("defaultFuelType") private var selectedFuelTypeRaw: String = FuelType.u91.rawValue
    @AppStorage("defaultFuelRegion") private var selectedRegionRaw: String = FuelRegion.all.rawValue

    @State private var guideExpanded = false
    @State private var showingSettings = false
    @State private var activePicker: ActivePicker?

    enum ActivePicker {
        case fuel
        case region
    }

    private var selectedFuelType: FuelType {
        FuelType(rawValue: selectedFuelTypeRaw) ?? .u91
    }

    private var selectedRegion: FuelRegion {
        FuelRegion(rawValue: selectedRegionRaw) ?? .all
    }

    private var rankedStations: [RankedFuelStation] {
        fuelService.stations(for: selectedFuelType, region: selectedRegion)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 18) {
                        howToBanner

                        if spoofManager.isSpoofing || spoofManager.isBusy {
                            activeSpoofBanner
                        }

                        if let error = spoofManager.errorMessage {
                            feedbackBanner(text: error, isError: true) {
                                spoofManager.errorMessage = nil
                            }
                        } else if let status = spoofManager.statusMessage, !spoofManager.isSpoofing {
                            feedbackBanner(text: status, isError: false) {
                                spoofManager.statusMessage = nil
                            }
                        }

                        if !spoofManager.isReadyToSpoof {
                            setupIncompleteBanner
                        }

                        fuelPricesSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color(.systemGroupedBackground))

                if let activePicker {
                    pickerOverlay(for: activePicker)
                }
            }
            .navigationTitle("8/12 Fuel Lock")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            Task { await fuelService.refresh(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(fuelService.isLoading)

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .refreshable {
                spoofManager.refreshState()
                await fuelService.refresh(force: true)
            }
            .task {
                spoofManager.refreshState()
                await fuelService.refresh(force: false)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    spoofManager.refreshState()
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(spoofManager)
            }
        }
    }

    // MARK: - Collapsible "How to Fuel Lock with 8/12" Banner

    private var howToBanner: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    guideExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "fuelpump.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.14), in: Circle())

                    Text("How to Fuel Lock with 8/12")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: guideExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if guideExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    guideStep(
                        number: 1,
                        title: "Run Spoof",
                        detail: "Tap \"Spoof Here\" on a cheap station below. Background keep-alive starts automatically."
                    )
                    guideStep(
                        number: 2,
                        title: "Start Fuel Lock & Wait for Price",
                        detail: "Open the 7-Eleven app, start Fuel Lock, and wait until the spoofed price appears."
                    )
                    guideStep(
                        number: 3,
                        title: "Turn Off Spoof",
                        detail: "Switch back to 8/12 and tap \"Stop Spoof\" to restore your real GPS location."
                    )
                    guideStep(
                        number: 4,
                        title: "Return & Claim",
                        detail: "Switch back to the 7-Eleven app and claim your locked fuel price!"
                    )
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func guideStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Setup Incomplete Banner

    private var setupIncompleteBanner: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(setupPromptTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to configure in Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var setupPromptTitle: String {
        if !spoofManager.pairingFileExists && !spoofManager.vpnConnected {
            return "Import pairing file & connect LocalDevVPN"
        } else if !spoofManager.pairingFileExists {
            return "Pairing file missing"
        } else {
            return "LocalDevVPN not connected"
        }
    }

    // MARK: - Active Spoof Banner

    private var activeSpoofBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if spoofManager.isBusy && !spoofManager.isSpoofing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(spoofStatusTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let station = spoofManager.activeStation {
                        Text("\(station.name) • \(station.formattedPrice) c/L • \(station.suburb)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                Spacer()
            }

            if spoofManager.isSpoofing {
                HStack(spacing: 10) {
                    Label("Keep-Alive Active", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.18), in: Capsule())

                    Spacer()

                    Button {
                        spoofManager.stopSpoofing()
                    } label: {
                        Text("Stop Spoof")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.white, in: Capsule())
                    }
                    .disabled(spoofManager.isBusy)
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.green.opacity(0.9), Color.teal],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var spoofStatusTitle: String {
        switch spoofManager.stage {
        case .idle: return "Ready"
        case .connecting: return "Connecting LocalDevVPN Tunnel…"
        case .downloadingDDI: return "Downloading Developer Disk Image…"
        case .mountingDDI: return "Mounting Cryptex Disk Image…"
        case .spoofing: return "GPS Spoofing Active"
        }
    }

    // MARK: - Cheapest 7-Eleven Fuel Section

    private var fuelPricesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Cheapest 7-Eleven Fuel")
                    .font(.headline)
                Spacer()
                if fuelService.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let updated = fuelService.updatedDate {
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Matching Fuel & State/Region selector pills
            HStack(spacing: 12) {
                SelectorPillButton(
                    title: "Fuel",
                    value: selectedFuelType.rawValue,
                    icon: "drop.fill"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activePicker = .fuel
                    }
                }

                SelectorPillButton(
                    title: "State",
                    value: selectedRegion.rawValue,
                    icon: "mappin.and.ellipse"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activePicker = .region
                    }
                }
            }

            if let error = fuelService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if rankedStations.isEmpty {
                VStack(spacing: 10) {
                    Text(fuelService.isLoading ? "Loading live prices…" : "No stations found for \(selectedFuelType.rawValue) in \(selectedRegion.rawValue).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !fuelService.isLoading {
                        Button("Retry") {
                            Task { await fuelService.refresh(force: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 14) {
                    ForEach(rankedStations) { item in
                        stationCard(item)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stationCard(_ item: RankedFuelStation) -> some View {
        let isThisStationActive = spoofManager.activeStation?.id == item.station.id && spoofManager.isSpoofing

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("#\(item.rank)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(item.rank == 1 ? .white : .secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        item.rank == 1 ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.station.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.station.locationSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(item.station.formattedPrice)
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text("c/L")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(selectedFuelType.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())

                Spacer()

                Button {
                    if isThisStationActive {
                        spoofManager.stopSpoofing()
                    } else {
                        spoofManager.spoof(station: item.station)
                    }
                } label: {
                    Label(
                        isThisStationActive ? "Stop Spoof" : "Spoof Here",
                        systemImage: isThisStationActive ? "location.slash.fill" : "location.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(isThisStationActive ? .red : .accentColor)
                .controlSize(.regular)
                .disabled(spoofManager.isBusy)
            }
        }
        .padding(16)
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    // MARK: - Picker Overlay

    @ViewBuilder
    private func pickerOverlay(for picker: ActivePicker) -> some View {
        switch picker {
        case .fuel:
            PickerOverlay(
                title: "Select Fuel Type",
                options: FuelType.allCases,
                selected: selectedFuelType,
                label: { $0.rawValue },
                onSelect: { selectedFuelTypeRaw = $0.rawValue },
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activePicker = nil
                    }
                }
            )
        case .region:
            PickerOverlay(
                title: "Select State / Region",
                options: FuelRegion.allCases,
                selected: selectedRegion,
                label: { $0.rawValue },
                onSelect: { selectedRegionRaw = $0.rawValue },
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activePicker = nil
                    }
                }
            )
        }
    }

    private func feedbackBanner(text: String, isError: Bool, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            (isError ? Color.red : Color.green).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
