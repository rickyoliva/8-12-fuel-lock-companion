import Foundation
import PairingHostFFI

/// Drives the on-device RPPairing host on iOS 27+: requests Local Network
/// permission, keeps the app alive via silent audio while the user approves
/// the PIN in Settings, advertises over Bonjour, runs `si_pairing_run_host`
/// off the main thread, and persists the resulting pairing file via
/// `PairingFileStore`. Mirrors SideInstaller's `PairingController`.
@MainActor
final class PairingController: ObservableObject {

    enum PairingState: Equatable {
        case idle
        case requestingLocalNetwork
        case waitingForDevice
        case advertising
        case awaitingPIN(String)
        case paired(deviceName: String, byteCount: Int)
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .requestingLocalNetwork, .waitingForDevice, .advertising, .awaitingPIN:
                return true
            case .idle, .paired, .failed, .cancelled:
                return false
            }
        }

        var activePIN: String? {
            if case .awaitingPIN(let pin) = self { return pin }
            return nil
        }

        var statusText: String {
            switch self {
            case .idle:
                return "Ready to pair"
            case .requestingLocalNetwork:
                return "Requesting Local Network permission…"
            case .waitingForDevice:
                return "Starting pairing host…"
            case .advertising:
                return "Advertising — open Settings › Privacy & Security › Developer Mode"
            case .awaitingPIN(let pin):
                return "Enter PIN \(pin) in Settings › Developer Mode"
            case .paired(let deviceName, let byteCount):
                return "Paired with \(deviceName) (\(byteCount) bytes)"
            case .failed(let message):
                return "Pairing failed: \(message)"
            case .cancelled:
                return "Pairing cancelled"
            }
        }
    }

    enum PairingError: LocalizedError, Equatable {
        case busy
        case unsupportedOS
        case localNetworkDenied
        case zeroBytes
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Pairing is already in progress."
            case .unsupportedOS:
                return "On-device self-pairing requires iOS 27 or later."
            case .localNetworkDenied:
                return "Local Network permission is off. Enable it in Settings › 8/12 Fuel Lock › Local Network, then try again."
            case .zeroBytes:
                return "Pairing produced an empty file. Make sure you approved the pairing request, then try again."
            case .failed(let message):
                return message
            }
        }
    }

    struct PairedDevice: Equatable {
        let path: String
        let deviceName: String
        let deviceModel: String
        let address: String
    }

    nonisolated static let minimumSelfPairingOSMajorVersion = 27

    /// True when this device runs iOS 27+ and can run the on-device RPPairing host.
    nonisolated static var deviceCanSelfPair: Bool {
        canSelfPair(osVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }

    nonisolated static func canSelfPair(osVersion: OperatingSystemVersion) -> Bool {
        osVersion.majorVersion >= minimumSelfPairingOSMajorVersion
    }

    @Published private(set) var state: PairingState = .idle

    var isRunning: Bool { running }

    private let hostName = "8/12 Fuel Lock"
    private let hostModel = "Mac17,7"
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive: KeepAlive
    private let overSettings: PairingCodeSurface = PairingNotification.shared
    private let documentsDirectoryProvider: () -> URL
    private let logHandler: (String) -> Void
    private let onPaired: (URL) -> Void

    private var running = false
    private var current: HostRun?

    private nonisolated static let altIRKKey = "rpPairingHostAltIRK"
    private nonisolated static var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: altIRKKey) }
    }

    private static var rustLogInstalled = false
    private static var rustLogSink: (@MainActor (String) -> Void)?

    @MainActor
    private final class HostRun {
        let name: String
        let stagedPath: String
        let destinationURL: URL
        let altIRK: String
        var continuation: CheckedContinuation<PairedDevice, Error>?
        var cancelled = false
        nonisolated(unsafe) let cancelHandle: OpaquePointer = si_pairing_cancel_new()

        init(
            name: String,
            stagedPath: String,
            destinationURL: URL,
            altIRK: String,
            continuation: CheckedContinuation<PairedDevice, Error>?
        ) {
            self.name = name
            self.stagedPath = stagedPath
            self.destinationURL = destinationURL
            self.altIRK = altIRK
            self.continuation = continuation
        }

        deinit {
            si_pairing_cancel_free(cancelHandle)
        }
    }

    init(
        documentsDirectoryProvider: @escaping () -> URL = { LocationSpoofManager.documentsDirectory },
        logHandler: @escaping (String) -> Void = { _ in },
        onPaired: @escaping (URL) -> Void = { _ in }
    ) {
        self.documentsDirectoryProvider = documentsDirectoryProvider
        self.logHandler = logHandler
        self.onPaired = onPaired
        self.keepAlive = KeepAlive { msg in
            Task { @MainActor in logHandler(msg) }
        }
        Self.installRustLoggingIfNeeded(sink: logHandler)
    }

    private static func installRustLoggingIfNeeded(sink: @escaping @MainActor (String) -> Void) {
        rustLogSink = sink
        guard !rustLogInstalled else { return }
        rustLogInstalled = true
        _ = si_log_init(rustLogCallback, nil)
    }

    /// Starts on-device self-pairing and resolves with the paired device info, or throws.
    @discardableResult
    func startAndWait() async throws -> PairedDevice {
        guard Self.deviceCanSelfPair else {
            state = .failed(PairingError.unsupportedOS.localizedDescription)
            throw PairingError.unsupportedOS
        }
        guard !running else {
            throw PairingError.busy
        }
        return try await withCheckedThrowingContinuation { cont in
            begin(makeRun(continuation: cont))
        }
    }

    /// Cancels an active self-pairing run at any stage.
    func cancel() {
        guard let run = current, !run.cancelled else { return }
        run.cancelled = true
        state = .cancelled
        resolve(run, .failure(CancellationError()))
        stopAdvertising()
        overSettings.finish(paired: false)
        si_pairing_cancel(run.cancelHandle)
        logHandler("RPPairing: cancellation requested.")
    }

    /// Deterministic state transition helper for unit testing and lifecycle updates.
    func applyEvent(_ event: PairingEvent) {
        switch event {
        case .reset:
            state = .idle
        case .localNetworkRequested:
            state = .requestingLocalNetwork
        case .localNetworkGranted:
            state = .waitingForDevice
        case .localNetworkDenied:
            state = .failed(PairingError.localNetworkDenied.localizedDescription)
        case .advertisingStarted:
            state = .advertising
        case .pinReceived(let pin):
            state = .awaitingPIN(pin)
        case .succeeded(let deviceName, let byteCount):
            state = .paired(deviceName: deviceName, byteCount: byteCount)
        case .failed(let message):
            state = .failed(message)
        case .cancelled:
            state = .cancelled
        }
    }

    enum PairingEvent: Equatable {
        case reset
        case localNetworkRequested
        case localNetworkGranted
        case localNetworkDenied
        case advertisingStarted
        case pinReceived(String)
        case succeeded(deviceName: String, byteCount: Int)
        case failed(String)
        case cancelled
    }

    private func makeRun(continuation: CheckedContinuation<PairedDevice, Error>?) -> HostRun {
        let docs = documentsDirectoryProvider()
        let destinationURL = PairingFileStore.standardURL(in: docs)
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuellock-rppair-\(UUID().uuidString).plist")

        // Seed the staging file with the existing pairing file (if valid) so the
        // host key pair and identifier are preserved across re-pairings.
        if PairingFileStore.hasNonEmptyFile(at: destinationURL) {
            try? FileManager.default.copyItem(at: destinationURL, to: stagedURL)
        }

        return HostRun(
            name: hostName,
            stagedPath: stagedURL.path,
            destinationURL: destinationURL,
            altIRK: Self.storedAltIRK,
            continuation: continuation
        )
    }

    private func begin(_ run: HostRun) {
        guard !running else {
            logHandler("RPPairing: already running.")
            resolve(run, .failure(PairingError.busy))
            return
        }
        running = true
        current = run
        applyEvent(.localNetworkRequested)
        logHandler("RPPairing: requesting Local Network permission…")

        Task {
            guard await localNetwork.request() else {
                logHandler("RPPairing: Local Network permission denied.")
                applyEvent(.localNetworkDenied)
                end(run)
                resolve(run, .failure(PairingError.localNetworkDenied))
                return
            }
            guard !run.cancelled else {
                end(run)
                return
            }
            logHandler("RPPairing: Local Network granted. Starting silent audio keep-alive.")
            keepAlive.startAudio()
            applyEvent(.localNetworkGranted)
            overSettings.start()
            runHost(run)
        }
    }

    private func runHost(_ run: HostRun) {
        let bind = bindAddress
        let name = run.name
        let model = hostModel
        let outPath = run.stagedPath
        let altIRK = run.altIRK

        nonisolated(unsafe) let ctx = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
        nonisolated(unsafe) let cancelHandle = run.cancelHandle

        logHandler("RPPairing: starting host (out=\(run.destinationURL.lastPathComponent))")

        DispatchQueue.global(qos: .userInitiated).async {
            var result = SIPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                "".withCString { idC in
                                    si_pairing_run_host(
                                        bindC,
                                        0,
                                        nameC,
                                        modelC,
                                        outC,
                                        irkC,
                                        idC,
                                        pairReadyCallback,
                                        pairPinCallback,
                                        ctx,
                                        cancelHandle,
                                        &result
                                    )
                                }
                            }
                        }
                    }
                }
            }

            let outcome: PairOutcome
            if rc == 0 {
                let issued = cStr(result.host_alt_irk_hex)
                if !issued.isEmpty { Self.storedAltIRK = issued }
                outcome = .success(
                    name: cStr(result.device_name),
                    model: cStr(result.device_model),
                    udid: cStr(result.device_udid),
                    path: cStr(result.pairing_file_path),
                    address: cStr(result.device_address)
                )
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "pairing failed (rc=\(rc))" : msg)
            }

            si_pairing_result_free(&result)
            Unmanaged<PairingController>.fromOpaque(ctx).release()

            DispatchQueue.main.async {
                self.finish(outcome, run)
            }
        }
    }

    private enum PairOutcome {
        case success(name: String, model: String, udid: String, path: String, address: String)
        case failure(String)
    }

    private func end(_ run: HostRun) {
        guard current === run else { return }
        running = false
        current = nil
    }

    private func resolve(_ run: HostRun, _ result: Result<PairedDevice, Error>) {
        guard let cont = run.continuation else { return }
        run.continuation = nil
        cont.resume(with: result)
    }

    private func finish(_ outcome: PairOutcome, _ run: HostRun) {
        stopAdvertising()
        keepAlive.stopAll()
        end(run)

        let stagedURL = URL(fileURLWithPath: run.stagedPath)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        switch outcome {
        case let .success(name, model, udid, path, address):
            let sourceURL = path.isEmpty ? stagedURL : URL(fileURLWithPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0
            guard size > 0 else {
                logHandler("RPPairing: pairing produced an empty file.")
                applyEvent(.failed(PairingError.zeroBytes.localizedDescription))
                overSettings.finish(paired: false)
                resolve(run, .failure(PairingError.zeroBytes))
                return
            }

            do {
                _ = try PairingFileStore.importFile(from: sourceURL, to: run.destinationURL)
                let savedSize = (try? FileManager.default.attributesOfItem(atPath: run.destinationURL.path)[.size] as? Int) ?? size
                let displayName = name.isEmpty ? "this iPhone" : name
                logHandler("RPPairing: paired \(model) (UDID \(udid)), saved to \(run.destinationURL.lastPathComponent) (\(savedSize) bytes).")
                applyEvent(.succeeded(deviceName: displayName, byteCount: savedSize))
                overSettings.finish(paired: true)
                onPaired(run.destinationURL)
                resolve(
                    run,
                    .success(
                        PairedDevice(
                            path: run.destinationURL.path,
                            deviceName: displayName,
                            deviceModel: model,
                            address: address
                        )
                    )
                )
            } catch {
                logHandler("RPPairing: failed to persist pairing file: \(error.localizedDescription)")
                applyEvent(.failed(error.localizedDescription))
                overSettings.finish(paired: false)
                resolve(run, .failure(error))
            }

        case let .failure(message):
            if run.cancelled {
                logHandler("RPPairing: stopped.")
                applyEvent(.cancelled)
            } else {
                logHandler("RPPairing: failed — \(message)")
                applyEvent(.failed(message))
            }
            overSettings.finish(paired: false)
            resolve(run, .failure(run.cancelled ? CancellationError() : PairingError.failed(message)))
        }
    }

    // MARK: - Bonjour Advertising

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        guard let run = current, !run.cancelled else { return }
        stopAdvertising()
        logHandler("RPPairing: advertising _remotepairing-pairable-host._tcp \(serviceID) on port \(port)")
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        applyEvent(.advertisingStarted)
    }

    fileprivate func presentPin(_ pin: String) {
        guard let run = current, !run.cancelled else { return }
        logHandler("RPPairing: PIN = \(pin) — enter it in Settings › Privacy & Security › Developer Mode.")
        applyEvent(.pinReceived(pin))
        overSettings.show(code: pin)
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    fileprivate static func handleRustLog(_ line: String) {
        rustLogSink?(line)
    }
}

// MARK: - C Callbacks

private let pairReadyCallback: SIPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx, let serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys, let vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: SIPairPinCb = { pin, ctx in
    guard let ctx, let pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private let rustLogCallback: SILogCallback = { _, msg in
    guard let msg else { return }
    let line = String(cString: msg)
    DispatchQueue.main.async {
        PairingController.handleRustLog(line)
    }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr else { return "" }
    return String(cString: ptr)
}
