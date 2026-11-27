import Darwin
import Foundation
import Testing
@testable import FuelLockCompanion

struct DeviceConnectionPortTests {

    private struct DialCaptured: Error, Equatable {
        let ip: String
        let port: UInt16
        let hostname: String
    }

    private func makeTempPairingFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceConnectionPortTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("pairingFile.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "private_key": Data([1, 2, 3, 4]),
                "public_key": Data([5, 6, 7, 8]),
                "identifier": "test-host-id"
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: fileURL)
        return fileURL
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "DeviceConnectionPortTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    private func ipv4String(_ addr: sockaddr_in) -> String {
        var sinAddr = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sinAddr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    @Test func parseEndpointComponentsDistinguishesExplicitAndOmittedPorts() {
        let bare = NetworkStatus.parseEndpointComponents("10.7.0.1")
        #expect(bare?.host == "10.7.0.1")
        #expect(bare?.explicitPort == nil)

        let cidr = NetworkStatus.parseEndpointComponents("10.7.0.1/32")
        #expect(cidr?.host == "10.7.0.1")
        #expect(cidr?.explicitPort == nil)

        let explicitDefault = NetworkStatus.parseEndpointComponents("10.7.0.1:49152")
        #expect(explicitDefault?.host == "10.7.0.1")
        #expect(explicitDefault?.explicitPort == 49152)

        let explicitCustom = NetworkStatus.parseEndpointComponents("10.7.0.1:55021")
        #expect(explicitCustom?.host == "10.7.0.1")
        #expect(explicitCustom?.explicitPort == 55021)

        let ipv6Explicit = NetworkStatus.parseEndpointComponents("[::1]:55021")
        #expect(ipv6Explicit?.host == "::1")
        #expect(ipv6Explicit?.explicitPort == 55021)
    }

    @Test func explicitPortDialsExactPortWithoutProbingOrCaching() throws {
        let pairingURL = try makeTempPairingFile()
        defer { try? FileManager.default.removeItem(at: pairingURL.deletingLastPathComponent()) }
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var probedPorts: [UInt16] = []
        var scanned = false

        let conn = DeviceConnection(
            userDefaults: defaults,
            portProbe: { _, port in
                probedPorts.append(port)
                return .init(result: .answered, summary: "answered")
            },
            portScanner: { _, _ in
                scanned = true
                return .init(port: 55021, summary: "found")
            },
            tunnelDialer: { _, addr, hostname in
                throw DialCaptured(
                    ip: ipv4String(addr),
                    port: UInt16(bigEndian: addr.sin_port),
                    hostname: hostname
                )
            }
        )

        do {
            try conn.connect(deviceIP: "10.7.0.1:55021", pairingFilePath: pairingURL.path)
            Issue.record("Expected DialCaptured")
        } catch let captured as DialCaptured {
            #expect(captured == DialCaptured(ip: "10.7.0.1", port: 55021, hostname: "FuelLockCompanion"))
        }

        #expect(probedPorts.isEmpty)
        #expect(scanned == false)
        #expect(conn.cachedPairingPort() == nil)
    }

    @Test func autoDiscoveryProbes49152FirstThenScansAndCachesDiscoveredPort() throws {
        let pairingURL = try makeTempPairingFile()
        defer { try? FileManager.default.removeItem(at: pairingURL.deletingLastPathComponent()) }
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var probedPorts: [UInt16] = []
        var skippedInScan: [UInt16] = []
        var logs: [String] = []

        let conn = DeviceConnection(
            userDefaults: defaults,
            portProbe: { _, port in
                probedPorts.append(port)
                return .init(result: .refused, summary: "refused the connection")
            },
            portScanner: { _, skipping in
                skippedInScan = skipping
                return .init(port: 55021, summary: "found on port 55021")
            },
            tunnelDialer: { _, addr, hostname in
                throw DialCaptured(
                    ip: ipv4String(addr),
                    port: UInt16(bigEndian: addr.sin_port),
                    hostname: hostname
                )
            }
        )

        do {
            try conn.connect(
                deviceIP: "10.7.0.1/32",
                pairingFilePath: pairingURL.path,
                log: { logs.append($0) }
            )
            Issue.record("Expected DialCaptured")
        } catch let captured as DialCaptured {
            #expect(captured == DialCaptured(ip: "10.7.0.1", port: 55021, hostname: "FuelLockCompanion"))
        }

        #expect(probedPorts == [49152])
        #expect(skippedInScan == [49152])
        #expect(conn.cachedPairingPort() == 55021)
        #expect(logs.contains { $0.contains("55021") })
    }

    @Test func reconnectUsesCachedPortFirstWithoutScanning() throws {
        let pairingURL = try makeTempPairingFile()
        defer { try? FileManager.default.removeItem(at: pairingURL.deletingLastPathComponent()) }
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(55021, forKey: DeviceConnection.cachedPortDefaultsKey)

        var probedPorts: [UInt16] = []
        var scanned = false

        let conn = DeviceConnection(
            userDefaults: defaults,
            portProbe: { _, port in
                probedPorts.append(port)
                return .init(result: .answered, summary: "answered the RPPairing handshake")
            },
            portScanner: { _, _ in
                scanned = true
                return .init(port: nil, summary: "should not scan")
            },
            tunnelDialer: { _, addr, hostname in
                throw DialCaptured(
                    ip: ipv4String(addr),
                    port: UInt16(bigEndian: addr.sin_port),
                    hostname: hostname
                )
            }
        )

        do {
            try conn.connect(deviceIP: "10.7.0.1", pairingFilePath: pairingURL.path)
            Issue.record("Expected DialCaptured")
        } catch let captured as DialCaptured {
            #expect(captured == DialCaptured(ip: "10.7.0.1", port: 55021, hostname: "FuelLockCompanion"))
        }

        #expect(probedPorts == [55021])
        #expect(scanned == false)
        #expect(conn.cachedPairingPort() == 55021)
    }

    @Test func staleCachedPortFallsBackTo49152ThenScansAndUpdatesCache() throws {
        let pairingURL = try makeTempPairingFile()
        defer { try? FileManager.default.removeItem(at: pairingURL.deletingLastPathComponent()) }
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(55021, forKey: DeviceConnection.cachedPortDefaultsKey)

        var probedPorts: [UInt16] = []
        var skippedInScan: [UInt16] = []

        let conn = DeviceConnection(
            userDefaults: defaults,
            portProbe: { _, port in
                probedPorts.append(port)
                return .init(result: .refused, summary: "refused the connection")
            },
            portScanner: { _, skipping in
                skippedInScan = skipping
                return .init(port: 56789, summary: "found on port 56789")
            },
            tunnelDialer: { _, addr, hostname in
                throw DialCaptured(
                    ip: ipv4String(addr),
                    port: UInt16(bigEndian: addr.sin_port),
                    hostname: hostname
                )
            }
        )

        do {
            try conn.connect(deviceIP: "10.7.0.1", pairingFilePath: pairingURL.path)
            Issue.record("Expected DialCaptured")
        } catch let captured as DialCaptured {
            #expect(captured == DialCaptured(ip: "10.7.0.1", port: 56789, hostname: "FuelLockCompanion"))
        }

        #expect(probedPorts == [55021, 49152])
        #expect(skippedInScan == [55021, 49152])
        #expect(conn.cachedPairingPort() == 56789)
    }

    @Test func silentProbeStopsEarlyWithoutScanning() throws {
        let pairingURL = try makeTempPairingFile()
        defer { try? FileManager.default.removeItem(at: pairingURL.deletingLastPathComponent()) }
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var scanned = false
        let conn = DeviceConnection(
            userDefaults: defaults,
            portProbe: { _, _ in
                .init(result: .silent, summary: "neither took nor refused the connection within 8 s")
            },
            portScanner: { _, _ in
                scanned = true
                return .init(port: 55021, summary: "found")
            }
        )

        #expect(throws: DeviceConnection.DeviceError.self) {
            try conn.connect(deviceIP: "10.7.0.1", pairingFilePath: pairingURL.path)
        }
        #expect(scanned == false)
    }

    @Test func rustProbeListenerHandlesInvalidAddress() {
        let probe = DeviceConnection.probeListener(deviceIP: "not-an-ip", port: 49152)
        #expect(probe.result == .failed)
        #expect(!probe.summary.isEmpty)
    }
}
