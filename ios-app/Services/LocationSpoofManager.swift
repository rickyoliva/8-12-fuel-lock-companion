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
    private var resendTimer: Timer?
    private static let resendInterval: TimeInterval = 4.0
    private static let deviceIPKey = "deviceIP"

    var isSpoofing: Bool { simulatedCoordinate != nil }
    var isReadyToSpoof: Bool { pairingFileExists && vpnConnected }

    init() {
        let savedIP = UserDefaults.standard.string(forKey: Self.deviceIPKey) ?? DeviceConnection.defaultDeviceIP
        self.deviceIP = savedIP
        refreshState()
    }

    func refreshState() {
        refreshPairingFile()
        refreshNetworkStatus()
    }

    func refreshPairingFile() {
        let path = Self.pairingFileURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        pairingFileExists = FileManager.default.fileExists(atPath: path) && size > 0
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

    func refreshNetworkStatus() {
        guard let endpoint = resolvedEndpoint else {
            vpnConnected = false
            return
        }
        vpnConnected = NetworkStatus.loopbackTunnelUp(deviceIP: endpoint.host)
    }

    // MARK: - Pairing File Import

    func importPairingFile(from url: URL) {
        errorMessage = nil
        statusMessage = nil

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let kind = PairingFileKind.of(data: data)
            guard kind.isUsable else {
                errorMessage = "That file doesn't look like an iOS pairing file."
                return
            }

            try FileManager.default.createDirectory(
                at: Self.pairingFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.pairingFileURL, options: .atomic)
            connection.disconnect()
            refreshPairingFile()

            if !kind.hasRemotePairing {
                errorMessage = "Imported a classic lockdown pairing file. On iOS 26.4+, use a Remote Pairing file (from idevice_pair, iLoader, or SideInstaller) for LocalDevVPN."
                appendLog("Imported classic lockdown pairing file (missing RemotePairing keys).")
            } else {
                statusMessage = "Pairing file imported and ready."
                appendLog("Imported Remote Pairing file (\(url.lastPathComponent)).")
            }
        } catch {
            errorMessage = "Couldn't import pairing file: \(error.localizedDescription)"
            appendLog("Pairing import failed: \(error.localizedDescription)")
        }
    }

    func removePairingFile() {
        try? FileManager.default.removeItem(at: Self.pairingFileURL)
        connection.disconnect()
        refreshPairingFile()
        statusMessage = "Pairing file removed."
        appendLog("Pairing file removed.")
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
            appendLog("Connecting to \(endpoint.host):\(endpoint.port) via LocalDevVPN…")
            try await onDeviceQueue {
                try self.connection.connect(deviceIP: endpoint.host, port: endpoint.port, pairingFilePath: pairingPath)
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

    static var pairingFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
        return docs.appendingPathComponent("pairing.mobiledevicepairing")
    }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
