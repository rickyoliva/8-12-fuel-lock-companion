import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var fuelService: FuelPriceService
    @EnvironmentObject private var spoofManager: LocationSpoofManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("defaultFuelType") private var selectedFuelTypeRaw: String = FuelType.u91.rawValue
    @AppStorage("defaultFuelRegion") private var selectedRegionRaw: String = FuelRegion.all.rawValue

    @State private var showingFileImporter = false
    @State private var showingLogSheet = false
    @State private var setupExpanded = true

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
            ScrollView {
                VStack(spacing: 16) {
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

                    setupCard
                    fuelPricesSection
                    fuelLockGuideCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("8/12 Fuel Lock")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await fuelService.refresh(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(fuelService.isLoading)

                        Button {
                            showingLogSheet = true
                        } label: {
                            Image(systemName: "terminal")
                        }
                    }
                }
            }
            .refreshable {
                spoofManager.refreshState()
                await fuelService.refresh(force: true)
            }
            .task {
                spoofManager.refreshState()
                if spoofManager.isReadyToSpoof {
                    setupExpanded = false
                }
                await fuelService.refresh(force: false)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    spoofManager.refreshState()
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.data, .propertyList],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        spoofManager.importPairingFile(from: url)
                        if spoofManager.isReadyToSpoof {
                            setupExpanded = false
                        }
                    }
                case .failure(let error):
                    spoofManager.errorMessage = "File import failed: \(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $showingLogSheet) {
                ActivityLogSheet(logs: spoofManager.logs)
            }
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

    // MARK: - Setup Card

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setupExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: spoofManager.isReadyToSpoof ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                        .foregroundStyle(spoofManager.isReadyToSpoof ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spoofing Setup")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(spoofManager.isReadyToSpoof
                             ? "Pairing file & LocalDevVPN ready"
                             : "Two quick steps before you can spoof")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: setupExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if setupExpanded {
                Divider()

                // 1. Pairing File
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: spoofManager.pairingFileExists ? "checkmark.circle.fill" : "1.circle.fill")
                        .font(.title3)
                        .foregroundStyle(spoofManager.pairingFileExists ? .green : .accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote Pairing File")
                            .font(.subheadline.weight(.semibold))
                        Text(spoofManager.pairingFileExists
                             ? "Imported — ready for iOS 26.4+ LocalDevVPN"
                             : "Import a Remote Pairing file from idevice_pair, iLoader, or SideInstaller.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(spoofManager.pairingFileExists ? "Replace" : "Import") {
                        showingFileImporter = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // 2. LocalDevVPN
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: spoofManager.vpnConnected ? "checkmark.circle.fill" : "2.circle.fill")
                        .font(.title3)
                        .foregroundStyle(spoofManager.vpnConnected ? .green : .accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("LocalDevVPN Tunnel")
                            .font(.subheadline.weight(.semibold))
                        Text(spoofManager.vpnConnected
                             ? "Connected (\(spoofManager.deviceIP))"
                             : "Turn on LocalDevVPN so 8/12 can simulate GPS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(spoofManager.vpnConnected ? "Refresh" : "Open VPN") {
                        if spoofManager.vpnConnected {
                            spoofManager.refreshNetworkStatus()
                        } else {
                            spoofManager.openLocalDevVPN()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                HStack {
                    Text("Device IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("10.7.0.1", text: $spoofManager.deviceIP)
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Fuel Prices Section

    private var fuelPricesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            // Fuel Type Picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FuelType.allCases) { fuel in
                        Button {
                            selectedFuelTypeRaw = fuel.rawValue
                        } label: {
                            Text(fuel.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    selectedFuelType == fuel
                                        ? Color.accentColor
                                        : Color(.tertiarySystemGroupedBackground),
                                    in: Capsule()
                                )
                                .foregroundStyle(selectedFuelType == fuel ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Region Picker
            Picker("Region", selection: $selectedRegionRaw) {
                ForEach(FuelRegion.allCases) { region in
                    Text(region.rawValue).tag(region.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if let error = fuelService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if rankedStations.isEmpty {
                VStack(spacing: 8) {
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
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(rankedStations) { item in
                        stationCard(item)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stationCard(_ item: RankedFuelStation) -> some View {
        let isThisStationActive = spoofManager.activeStation?.id == item.station.id && spoofManager.isSpoofing

        return HStack(spacing: 12) {
            Text("#\(item.rank)")
                .font(.caption.weight(.bold))
                .foregroundStyle(item.rank == 1 ? .white : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    item.rank == 1 ? Color.accentColor : Color(.tertiarySystemGroupedBackground),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.station.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.station.locationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(item.station.formattedPrice)
                        .font(.title3.weight(.bold).monospacedDigit())
                    Text("c/L")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Button {
                    if isThisStationActive {
                        spoofManager.stopSpoofing()
                    } else {
                        spoofManager.spoof(station: item.station)
                    }
                } label: {
                    Text(isThisStationActive ? "Stop Spoof" : "Spoof Here")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(isThisStationActive ? .red : .accentColor)
                .controlSize(.small)
                .disabled(spoofManager.isBusy)
            }
        }
        .padding(12)
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: - Step-by-Step Fuel Lock Guide

    private var fuelLockGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How to Fuel Lock (4 Steps)", systemImage: "fuelpump.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                guideStep(
                    number: 1,
                    title: "Run Spoof",
                    detail: "Tap \"Spoof Here\" on a cheap station above. Background keep-alive starts automatically."
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
        .padding(16)
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

private struct ActivityLogSheet: View {
    let logs: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if logs.isEmpty {
                        Text("No activity yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
