import CoreLocation
import Foundation
import UIKit

/// Coordinates pairing file management, LocalDevVPN detection, Developer Disk Image
/// download/mounting, and active GPS spoofing with background keep-alive.
@MainActor
final class LocationSpoofManager: ObservableObject {

    enum Stage: Equatable {
        case idle
        case connecting
        case downloadingDDI
        case mountingDDI
        case spoofing
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var activeStation: FuelStation?
    @Published private(set) var simulatedCoordinate: CLLocationCoordinate2D?
    @Published private(set) var pairingFileExists = false
    @Published private(set) var pairingFileKind: PairingFileKind?
    @Published private(set) var vpnConnected = false
    @Published private(set) var localDevVPNInstalled = false
    @Published private(set) var pairingState: PairingController.PairingState = .idle
    @Published private(set) var pairingPIN: String?
    @Published private(set) var logs: [String] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    @Published var deviceIP: String {
        didSet {
            UserDefaults.standard.set(deviceIP, forKey: Self.deviceIPKey)
            if oldValue != deviceIP && !isSpoofing {
                connection.disconnect()
            }
            refreshNetworkStatus()
        }
    }

    private let connection = DeviceConnection()
    private let deviceQueue = DispatchQueue(label: "com.rickyoliva.fuellock.device", qos: .userInitiated)
    private lazy var keepAlive = KeepAlive { [weak self] msg in
        Task { @MainActor in self?.appendLog(msg) }
    }
    private lazy var pairingController: PairingController = {
        let controller = PairingController(
            documentsDirectoryProvider: { Self.documentsDirectory },
            logHandler: { [weak self] msg in
                self?.appendLog(msg)
            },
            onPaired: { [weak self] _ in
                guard let self else { return }
                self.connection.disconnect()
                self.refreshPairingFile()
            }
        )
        return controller
    }()
    private var pairingStateObservation: Task<Void, Never>?
    private var resendTimer: Timer?
    private static let resendInterval: TimeInterval = 4.0
    private static let deviceIPKey = "deviceIP"

    nonisolated static var deviceCanSelfPair: Bool { PairingController.deviceCanSelfPair }
    var isSelfPairing: Bool { pairingState.isActive }
    var isSpoofing: Bool { simulatedCoordinate != nil }
    var isReadyToSpoof: Bool { pairingFileExists && vpnConnected }
    var isLocalDevVPNDetected: Bool { localDevVPNInstalled || vpnConnected }

    init() {
        let savedIP = UserDefaults.standard.string(forKey: Self.deviceIPKey) ?? DeviceConnection.defaultDeviceIP
        self.deviceIP = savedIP
        refreshState()
    }

    func refreshState() {
        refreshPairingFile()
        refreshNetworkStatus()
        refreshLocalDevVPNInstalled()
    }

    func refreshLocalDevVPNInstalled() {
        if let url = URL(string: "localdevvpn://") {
            localDevVPNInstalled = UIApplication.shared.canOpenURL(url)
        } else {
            localDevVPNInstalled = false
        }
    }

    func refreshPairingFile() {
        if PairingFileStore.migrateLegacyIfNeeded(in: Self.documentsDirectory) {
            appendLog("Migrated legacy pairing file to \(PairingFileStore.standardFilename).")
        }
        let path = Self.pairingFileURL.path
        pairingFileExists = PairingFileStore.hasNonEmptyFile(at: Self.pairingFileURL)
        pairingFileKind = pairingFileExists ? PairingFileKind.of(path: path) : nil
    }

    var isDeviceEndpointValid: Bool {
        let trimmed = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || NetworkStatus.parseEndpoint(trimmed) != nil
    }

    var resolvedEndpoint: NetworkStatus.Endpoint? {
        let trimmed = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NetworkStatus.Endpoint(host: DeviceConnection.defaultDeviceIP, port: DeviceConnection.rsdPort)
        }
        return NetworkStatus.parseEndpoint(trimmed)
    }

    var resolvedExplicitPort: UInt16? {
        let trimmed = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NetworkStatus.parseEndpointComponents(trimmed)?.explicitPort
    }

    func refreshNetworkStatus() {
        guard let endpoint = resolvedEndpoint else {
            vpnConnected = false
            return
        }
        vpnConnected = NetworkStatus.loopbackTunnelUp(deviceIP: endpoint.host)
    }

    // MARK: - Pairing File Import

    func handleIncomingURL(_ url: URL) {
        guard url.isFileURL else { return }
        appendLog("Received pairing file via Share Sheet / Files: \(url.lastPathComponent)")
        importPairingFile(from: url, sourceLabel: "Share Sheet / Files")
    }

    func importPairingFile(from url: URL, sourceLabel: String? = nil) {
        errorMessage = nil
        statusMessage = nil

        do {
            let result = try PairingFileStore.importFile(from: url, to: Self.pairingFileURL)
            connection.disconnect()
            refreshPairingFile()

            if !result.kind.hasRemotePairing {
                errorMessage = "Imported a classic lockdown pairing file. On iOS 26.4+, use a Remote Pairing file (from idevice_pair, iLoader, or SideInstaller) for LocalDevVPN."
                appendLog("Imported classic lockdown pairing file (missing RemotePairing keys).")
            } else {
                let via = sourceLabel.map { " via \($0)" } ?? ""
                statusMessage = "Pairing file imported\(via) and saved to \(PairingFileStore.standardFilename)."
                appendLog("Imported Remote Pairing file (\(result.filename))\(via).")
            }
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Pairing import failed: \(error.localizedDescription)")
        }
    }

    func removePairingFile() {
        try? FileManager.default.removeItem(at: Self.pairingFileURL)
        try? FileManager.default.removeItem(at: PairingFileStore.legacyURL(in: Self.documentsDirectory))
        connection.disconnect()
        refreshPairingFile()
        statusMessage = "Pairing file removed."
        appendLog("Pairing file removed.")
    }

    // MARK: - On-Device Self-Pairing (iOS 27+)

    func startSelfPairing() {
        guard !isSelfPairing else { return }
        errorMessage = nil
        statusMessage = nil

        if pairingStateObservation == nil {
            pairingStateObservation = Task { [weak self] in
                guard let self else { return }
                for await newState in self.pairingController.$state.values {
                    self.pairingState = newState
                    self.pairingPIN = newState.activePIN
                }
            }
        }

        Task {
            do {
                let paired = try await pairingController.startAndWait()
                statusMessage = "Paired \(paired.deviceName) and saved \(PairingFileStore.standardFilename)."
            } catch is CancellationError {
                statusMessage = "Self-pairing cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSelfPairing() {
        pairingController.cancel()
    }

    func openLocalDevVPN() {
        guard let url = URL(string: "localdevvpn://") else { return }
        UIApplication.shared.open(url)
    }

    func openSevenElevenApp() {
        if let url = URL(string: "au.com.fuel.seveneleven://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Spoofing Lifecycle

    func spoof(station: FuelStation) {
        guard !isBusy else { return }
        refreshState()

        guard pairingFileExists else {
            errorMessage = "Import your pairing file first in the Setup card above."
            return
        }
        guard vpnConnected else {
            errorMessage = "Connect LocalDevVPN first, then tap Spoof Here."
            return
        }

        isBusy = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                try await ensureReadyAndSpoof(coordinate: station.coordinate, station: station)
                statusMessage = "Spoofing \(station.name) (\(station.formattedPrice) c/L). Background keep-alive is active."
            } catch {
                stage = .idle
                simulatedCoordinate = nil
                activeStation = nil
                stopResending()
                keepAlive.stopAll()
                errorMessage = error.localizedDescription
                appendLog("Spoof failed: \(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    func stopSpoofing() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        stopResending()

        Task {
            defer {
                simulatedCoordinate = nil
                activeStation = nil
                stage = .idle
                keepAlive.stopAll()
                isBusy = false
            }
            do {
                try await onDeviceQueue {
                    try self.connection.clearSimulatedLocation()
                    self.connection.endLocationSimulation()
                }
                statusMessage = "Spoof stopped. Your real GPS location is restored."
                appendLog("Simulated location cleared.")
            } catch {
                errorMessage = "Stopped keep-alive, but clearing location reported: \(error.localizedDescription)"
                appendLog("Clear location error: \(error.localizedDescription)")
            }
        }
    }

    private func ensureReadyAndSpoof(coordinate: CLLocationCoordinate2D, station: FuelStation) async throws {
        guard let endpoint = resolvedEndpoint else {
            throw DeviceConnection.DeviceError.message(
                "Invalid device endpoint: \(deviceIP). Enter an IP or host:port (e.g. 10.7.0.1 or 10.7.0.1:49152)."
            )
        }
        let pairingPath = Self.pairingFileURL.path

        if !connection.isConnected {
            stage = .connecting
            let explicitPort = resolvedExplicitPort
            let targetLabel = explicitPort.map { "\(endpoint.host):\($0)" } ?? endpoint.host
            appendLog("Connecting to \(targetLabel) via LocalDevVPN…")
            try await onDeviceQueue {
                try self.connection.connect(
                    deviceIP: endpoint.host,
                    port: explicitPort,
                    pairingFilePath: pairingPath,
                    log: { [weak self] msg in
                        Task { @MainActor in self?.appendLog(msg) }
                    }
                )
            }
            appendLog("Tunnel connected.")
        }

        if !connection.isSimulatingLocation {
            try await prepareDeveloperDiskImage()
            try await onDeviceQueue {
                try self.connection.beginLocationSimulation()
            }
            appendLog("DVT location simulation session opened.")
        }

        try await onDeviceQueue {
            try self.connection.setSimulatedLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }

        activeStation = station
        simulatedCoordinate = coordinate
        stage = .spoofing
        keepAlive.startAudio()
        startResending()
        appendLog(String(format: "Spoofing %@ (%.5f, %.5f).", station.name, coordinate.latitude, coordinate.longitude))
    }

    private func prepareDeveloperDiskImage() async throws {
        let checksCryptex = DeveloperDiskImage.installsAsCryptex
        let present = try await onDeviceQueue {
            try self.connection.developerImagePresence(checkingCryptex: checksCryptex)
        }
        if let present {
            appendLog("Developer Disk Image already present (\(present)).")
            return
        }

        var firstFailure: Error?
        for variant in DeveloperDiskImage.variants {
            do {
                if !DeveloperDiskImage.isDownloaded(variant) {
                    stage = .downloadingDDI
                    appendLog("Downloading Developer Disk Image (\(variant.logName))…")
                    try await DeveloperDiskImage.downloadMissing(variant, log: { [weak self] msg in
                        Task { @MainActor in self?.appendLog(msg) }
                    }) { _ in }
                }
                stage = .mountingDDI
                switch variant {
                case .cryptex:
                    appendLog("Installing Developer Disk Image as Cryptex (iOS 26.4+)…")
                    let dir = DeveloperDiskImage.cryptexDirectory
                    let version = try await onDeviceQueue {
                        try self.connection.installCryptexDeveloperImage(directory: dir)
                    }
                    appendLog("Cryptex DDI installed\(version.isEmpty ? "" : " (\(version))").")
                case .personalized:
                    appendLog("Mounting personalized Developer Disk Image…")
                    try await onDeviceQueue {
                        try self.connection.mountPersonalizedDeveloperImage(
                            imagePath: DeveloperDiskImage.imagePath,
                            trustcachePath: DeveloperDiskImage.trustcachePath,
                            manifestPath: DeveloperDiskImage.manifestPath
                        )
                    }
                    appendLog("Personalized DDI mounted.")
                }
                return
            } catch {
                if firstFailure == nil { firstFailure = error }
                appendLog("DDI \(variant.logName) failed: \(error.localizedDescription)")
            }
        }
        throw firstFailure ?? DeviceConnection.DeviceError.message("Failed to install Developer Disk Image.")
    }

    private func startResending() {
        stopResending()
        resendTimer = Timer.scheduledTimer(withTimeInterval: Self.resendInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let coord = self.simulatedCoordinate else { return }
                guard self.connection.isSimulatingLocation else {
                    self.sessionClosed()
                    return
                }
                try? await self.onDeviceQueue {
                    try self.connection.setSimulatedLocation(latitude: coord.latitude, longitude: coord.longitude)
                }
            }
        }
    }

    private func stopResending() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func sessionClosed() {
        stopResending()
        simulatedCoordinate = nil
        activeStation = nil
        stage = .idle
        keepAlive.stopAll()
        errorMessage = "Location session closed. Tap Spoof Here again."
        appendLog("Location session closed unexpectedly.")
    }

    private func onDeviceQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            deviceQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func appendLog(_ message: String) {
        let timestamp = Self.logFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    var formattedLogs: String {
        logs.joined(separator: "\n")
    }

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
    }

    static var pairingFileURL: URL {
        PairingFileStore.standardURL(in: documentsDirectory)
    }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
