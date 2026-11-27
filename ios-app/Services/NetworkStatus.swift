import Darwin
import Foundation

/// Detects the loopback tunnel (e.g. LocalDevVPN `utun*` interface) by
/// scanning active interfaces and checking the kernel routing table.
enum NetworkStatus {

    struct Interface {
        let name: String
        let ipv4: String
        let netmask: String?
    }

    enum TunnelRoute: Equatable {
        case dedicated
        case other
        case fullTunnel(interface: String, source: String)
    }

    enum ProbeResult: Equatable {
        case connected
        case refused
        case timedOut
        case failed(errno: Int32)

        var answered: Bool { self == .connected || self == .refused }
    }

    struct ProbeTarget: Equatable {
        let deviceIP: String
        let interface: String
        let source: String
    }

    struct Scan {
        let route: TunnelRoute
        let fallbackMatch: Bool
        let wifi: Bool
        let detail: String
        let probeTarget: ProbeTarget?
    }

    private static let defaultRouteProbe = "203.0.113.1"

    static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard let ipv4 = numericHost(addr) else { continue }
            result.append(Interface(
                name: name,
                ipv4: ipv4,
                netmask: cur.pointee.ifa_netmask.flatMap(numericHost)
            ))
        }
        return result
    }

    static func scan(deviceIP: String) -> Scan {
        let ifs = interfaces()
        let (route, fallbackMatch) = tunnelRoute(in: ifs, deviceIP: deviceIP)
        var probeTarget: ProbeTarget?
        if case .fullTunnel(let interface, let source) = route, !fallbackMatch {
            probeTarget = ProbeTarget(deviceIP: deviceIP, interface: interface, source: source)
        }
        return Scan(
            route: route,
            fallbackMatch: fallbackMatch,
            wifi: ifs.contains { $0.name == "en0" },
            detail: ifs.map { "\($0.name)=\($0.ipv4)" }.joined(separator: ", "),
            probeTarget: probeTarget
        )
    }

    static func tunnelIsUp(route: TunnelRoute, fallbackMatch: Bool, probe: ProbeResult?) -> Bool {
        switch route {
        case .dedicated: return true
        case .other: return fallbackMatch
        case .fullTunnel: return fallbackMatch || probe?.answered == true
        }
    }

    static func loopbackTunnelUp(deviceIP: String) -> Bool {
        let (route, fallbackMatch) = tunnelRoute(in: interfaces(), deviceIP: deviceIP)
        return tunnelIsUp(route: route, fallbackMatch: fallbackMatch, probe: nil)
    }

    static func host(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return trimmed }
        return String(trimmed[..<slash]).trimmingCharacters(in: .whitespaces)
    }

    static func isOwnAddress(_ deviceIP: String) -> Bool {
        interfaces().contains { $0.ipv4 == deviceIP }
    }

    private static func tunnelRoute(in ifs: [Interface], deviceIP: String) -> (route: TunnelRoute, fallbackMatch: Bool) {
        guard let target = ipv4Value(deviceIP) else {
            return (.other, ifs.contains { isTunnelInterface($0.name) })
        }
        let route = tunnelRoute(to: deviceIP, in: ifs)
        let fallbackMatch = route != .dedicated
            && ifs.contains { isTunnelInterface($0.name) && subnet($0, contains: target) }
        return (route, fallbackMatch)
    }

    private static func tunnelRoute(to deviceIP: String, in ifs: [Interface]) -> TunnelRoute {
        guard let source = routeSource(to: deviceIP),
              let iface = ifs.first(where: { $0.ipv4 == source })
        else { return .other }
        guard isTunnelInterface(iface.name) else { return .other }
        if routeSource(to: defaultRouteProbe) != source { return .dedicated }
        return .fullTunnel(interface: iface.name, source: source)
    }

    private static func routeSource(to ip: String) -> String? {
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(UInt16(9).bigEndian)
        guard ip.withCString({ inet_pton(AF_INET, $0, &remote.sin_addr) }) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let dialled = withUnsafePointer(to: remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard dialled == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0, local.sin_addr.s_addr != 0 else { return nil }
        return withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, numericHost)
        }
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    private static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tap") || name.hasPrefix("ppp")
    }

    private static func subnet(_ interface: Interface, contains target: UInt32) -> Bool {
        guard let address = ipv4Value(interface.ipv4) else { return false }
        guard let mask = interface.netmask.flatMap(ipv4Value), mask != 0 else {
            return (address & 0xFFFF_FF00) == (target & 0xFFFF_FF00)
        }
        return (address & mask) == (target & mask)
    }

    private static func ipv4Value(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
