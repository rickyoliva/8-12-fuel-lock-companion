import Darwin
import Foundation
import IDevice

/// Inspects what kind of records a pairing file carries.
struct PairingFileKind: Equatable {
    let hasRemotePairing: Bool
    let hasLockdown: Bool

    var isUsable: Bool { hasRemotePairing || hasLockdown }

    static func of(path: String) -> PairingFileKind {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return PairingFileKind(hasRemotePairing: false, hasLockdown: false)
        }
        return of(data: data)
    }

    static func of(data: Data) -> PairingFileKind {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return PairingFileKind(hasRemotePairing: false, hasLockdown: false)
        }
        let hasRemote = plist["private_key"] != nil
            || plist["public_key"] != nil
            || plist["remote_unlock_host_key"] != nil
            || plist["RemotePairing"] != nil
        let hasLockdown = plist["HostCertificate"] != nil && plist["HostPrivateKey"] != nil
        return PairingFileKind(hasRemotePairing: hasRemote, hasLockdown: hasLockdown)
    }
}

/// Manages the loopback RPPairing tunnel, Cryptex/Personalized DDI mounting,
/// and DVT `LocationSimulation` session over `IDevice`.
final class DeviceConnection {

    static let defaultDeviceIP = "10.7.0.1"
    static let rsdPort: UInt16 = 49152

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSim: OpaquePointer?

    var isConnected: Bool { adapter != nil && handshake != nil }
    var isSimulatingLocation: Bool { locationSim != nil }

    deinit {
        disconnect()
    }

    func disconnect() {
        endLocationSimulation()
        if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
        if let adapter { adapter_close(adapter); self.adapter = nil }
    }

    // MARK: - Tunnel Connection

    func connect(
        deviceIP: String,
        port: UInt16? = nil,
        pairingFilePath: String,
        hostname: String = "FuelLockCompanion"
    ) throws {
        let fallbackPort = port ?? Self.rsdPort
        let trimmed = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: NetworkStatus.Endpoint
        if trimmed.isEmpty {
            endpoint = NetworkStatus.Endpoint(host: Self.defaultDeviceIP, port: fallbackPort)
        } else if let parsed = NetworkStatus.parseEndpoint(trimmed, defaultPort: fallbackPort) {
            endpoint = parsed
        } else {
            throw DeviceError.message("Invalid device endpoint: \(deviceIP)")
        }

        let kind = PairingFileKind.of(path: pairingFilePath)
        guard kind.isUsable else {
            throw DeviceError.message(
                "\((pairingFilePath as NSString).lastPathComponent) isn't a valid pairing file."
            )
        }
        guard kind.hasRemotePairing else {
            throw DeviceError.message(
                "This looks like a classic lockdown pairing file, which iOS 26.4+ rejects over LocalDevVPN. Create a Remote Pairing file using idevice_pair (\"Remote pairing\"), iLoader, or SideInstaller and import that instead."
            )
        }

        var pf: OpaquePointer?
        try pairingFilePath.withCString { p in
            try check(rp_pairing_file_read(p, &pf), "Failed to read pairing file")
        }
        guard let pairingFile = pf else {
            throw DeviceError.message("Pairing file handle was null.")
        }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = try Self.resolveIPv4Address(host: endpoint.host, port: endpoint.port)

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let err = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                hostname.withCString { host in
                    tunnel_create_rppairing(
                        sa,
                        idevice_socklen_t(MemoryLayout<sockaddr_in>.stride),
                        host,
                        pairingFile,
                        nil,
                        nil,
                        &newAdapter,
                        &newHandshake
                    )
                }
            }
        }
        try check(
            err,
            "Couldn't open tunnel to \(endpoint.host):\(endpoint.port). Make sure LocalDevVPN is connected, Wi-Fi is on, and Developer Mode is enabled."
        )
        guard let newAdapter, let newHandshake else {
            throw DeviceError.message("Tunnel opened without valid adapter/handshake handles.")
        }

        disconnect()
        self.adapter = newAdapter
        self.handshake = newHandshake
    }

    private static func resolveIPv4Address(host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 {
            return addr
        }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
        defer { if let result { freeaddrinfo(result) } }
        guard status == 0,
              let resolved = result,
              let aiAddr = resolved.pointee.ai_addr,
              resolved.pointee.ai_addrlen >= MemoryLayout<sockaddr_in>.size
        else {
            throw DeviceError.message("Invalid device IP or host: \(host)")
        }

        var resolvedAddr = aiAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        resolvedAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        resolvedAddr.sin_port = port.bigEndian
        return resolvedAddr
    }

    // MARK: - Developer Disk Image (Cryptex for iOS 26.4+ & Personalized Fallback)

    func developerImagePresence(checkingCryptex: Bool) throws -> String? {
        var cryptexAnswered = false
        var cryptexFailure: Error?
        if checkingCryptex {
            do {
                if let version = try installedCryptexDeveloperImage() {
                    return version.isEmpty ? "a cryptex" : "cryptex \(version)"
                }
                cryptexAnswered = true
            } catch {
                cryptexFailure = error
            }
        }
        do {
            let count = try mountedDeveloperImageCount()
            return count > 0 ? "\(count) image(s) mounted" : nil
        } catch {
            if cryptexAnswered { return nil }
            throw cryptexFailure ?? error
        }
    }

    func installedCryptexDeveloperImage() throws -> String? {
        guard let adapter, let handshake else { throw DeviceError.message("Not connected.") }
        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        try check(cryptexd_installed_ddi(adapter, handshake, &installed), "cryptexd_installed_ddi failed")
        guard let installed else { return nil }
        defer { cryptexd_free_installed_cryptex(installed) }
        return installed.pointee.version.map { String(cString: $0) } ?? ""
    }

    @discardableResult
    func installCryptexDeveloperImage(directory: String) throws -> String {
        guard let adapter, let handshake else { throw DeviceError.message("Not connected.") }
        var assets: OpaquePointer?
        try check(
            directory.withCString { cryptex1_assets_load($0, &assets) },
            "Loading Developer Disk Image cryptex from \(directory) failed"
        )
        guard let assets else { throw DeviceError.message("Cryptex assets handle was null.") }
        defer { cryptex1_assets_free(assets) }

        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        try check(
            cryptexd_install_ddi(adapter, handshake, assets, &installed),
            "Installing Developer Disk Image cryptex failed"
        )
        guard let installed else { return "" }
        defer { cryptexd_free_installed_cryptex(installed) }
        return installed.pointee.version.map { String(cString: $0) } ?? ""
    }

    func mountedDeveloperImageCount() throws -> Int {
        guard let adapter, let handshake else { throw DeviceError.message("Not connected.") }
        var client: OpaquePointer?
        try check(image_mounter_connect_rsd(adapter, handshake, &client), "image_mounter_connect_rsd failed")
        guard let client else { throw DeviceError.message("Image mounter client was null.") }
        defer { image_mounter_free(client) }

        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        try check(image_mounter_copy_devices(client, &devices, &count), "image_mounter_copy_devices failed")
        if let devices {
            for i in 0..<count { plist_free(devices[i]) }
            idevice_data_free(
                UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                UInt(count * MemoryLayout<plist_t?>.stride)
            )
        }
        return count
    }

    func mountPersonalizedDeveloperImage(
        imagePath: String,
        trustcachePath: String,
        manifestPath: String
    ) throws {
        guard let adapter, let handshake else { throw DeviceError.message("Not connected.") }
        let image = try Data(contentsOf: URL(fileURLWithPath: imagePath), options: .mappedIfSafe)
        let trustcache = try Data(contentsOf: URL(fileURLWithPath: trustcachePath), options: .mappedIfSafe)
        let manifest = try Data(contentsOf: URL(fileURLWithPath: manifestPath), options: .mappedIfSafe)
        guard !image.isEmpty, !trustcache.isEmpty, !manifest.isEmpty else {
            throw DeviceError.message("Developer Disk Image files are empty.")
        }

        let chipID = try uniqueChipID()

        var client: OpaquePointer?
        try check(image_mounter_connect_rsd(adapter, handshake, &client), "image_mounter_connect_rsd failed")
        guard let client else { throw DeviceError.message("Image mounter client was null.") }
        defer { image_mounter_free(client) }

        let err = image.withUnsafeBytes { img in
            trustcache.withUnsafeBytes { tc in
                manifest.withUnsafeBytes { man in
                    image_mounter_mount_personalized_with_callback_rsd(
                        client,
                        adapter,
                        handshake,
                        img.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        tc.bindMemory(to: UInt8.self).baseAddress,
                        trustcache.count,
                        man.bindMemory(to: UInt8.self).baseAddress,
                        manifest.count,
                        nil,
                        chipID,
                        nil,
                        nil
                    )
                }
            }
        }
        try check(err, "Mounting personalized Developer Disk Image failed")
    }

    private func uniqueChipID() throws -> UInt64 {
        guard let adapter, let handshake else { throw DeviceError.message("Not connected.") }
        var client: OpaquePointer?
        try check(lockdownd_connect_rsd(adapter, handshake, &client), "lockdownd_connect_rsd failed")
        guard let client else { throw DeviceError.message("lockdownd client was null.") }
        defer { lockdownd_client_free(client) }

        var value: plist_t?
        try check("UniqueChipID".withCString { lockdownd_get_value(client, $0, nil, &value) }, "lockdownd_get_value(UniqueChipID) failed")
        guard let value else { throw DeviceError.message("Device reported no UniqueChipID.") }
        defer { plist_free(value) }

        var chipID: UInt64 = 0
        plist_get_uint_val(value, &chipID)
        guard chipID != 0 else { throw DeviceError.message("Device reported empty UniqueChipID.") }
        return chipID
    }

    // MARK: - Location Simulation (DVT over RSD)

    func beginLocationSimulation() throws {
        if locationSim != nil { return }
        guard let adapter, let handshake else { throw DeviceError.message("Not connected.") }

        var server: OpaquePointer?
        try check(remote_server_connect_rsd(adapter, handshake, &server), "remote_server_connect_rsd failed")
        guard let server else { throw DeviceError.message("Remote server handle was null.") }

        var sim: OpaquePointer?
        let err = location_simulation_new(server, &sim)
        if err != nil {
            remote_server_free(server)
            try check(err, "location_simulation_new failed")
        }
        guard let sim else {
            remote_server_free(server)
            throw DeviceError.message("Location simulation handle was null.")
        }
        remoteServer = server
        locationSim = sim
    }

    func setSimulatedLocation(latitude: Double, longitude: Double) throws {
        guard let locationSim else { throw DeviceError.message("Location simulation not started.") }
        try check(location_simulation_set(locationSim, latitude, longitude), "location_simulation_set failed")
    }

    func clearSimulatedLocation() throws {
        guard let locationSim else { return }
        try check(location_simulation_clear(locationSim), "location_simulation_clear failed")
    }

    func endLocationSimulation() {
        if let locationSim {
            location_simulation_free(locationSim)
            self.locationSim = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
    }

    // MARK: - FFI Error Helper

    private func check(_ err: UnsafeMutablePointer<IdeviceFfiError>?, _ context: String) throws {
        guard let err else { return }
        let code = err.pointee.code
        let message = err.pointee.message.map { String(cString: $0) } ?? "unknown error"
        idevice_error_free(err)
        throw DeviceError.message("\(context): \(message) (code \(code))")
    }

    enum DeviceError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}
