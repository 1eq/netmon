import Darwin
import Foundation

/// Outcome of a single ICMP echo probe.
struct ProbeResult {
    enum Kind { case echoReply, timeExceeded, unreachable, timeout, sendFailed }
    let kind: Kind
    /// Address of whoever answered (destination, or the router whose TTL expired).
    let responder: String?
    /// Round-trip time in milliseconds; nil when nothing answered.
    let rtt: Double?

    var answered: Bool { rtt != nil }
}

enum IPFamily: String, Codable {
    case v4, v6

    /// The family of a numeric address, or nil if `ip` isn't one.
    init?(address ip: String) {
        if SocketAddress(ip, port: 0)?.family == AF_INET { self = .v4 }
        else if SocketAddress(ip, port: 0)?.family == AF_INET6 { self = .v6 }
        else { return nil }
    }

    var label: String { self == .v4 ? "IPv4" : "IPv6" }
    var addressFamily: Int32 { self == .v4 ? AF_INET : AF_INET6 }
}

/// A numeric IPv4 or IPv6 address as a `sockaddr`, for the BSD socket calls.
struct SocketAddress {
    private var storage = sockaddr_storage()
    let family: Int32

    init?(_ ip: String, port: UInt16) {
        var s = sockaddr_storage()
        let ok: Bool = withUnsafeMutablePointer(to: &s) { raw in
            var sin = sockaddr_in()
            if inet_pton(AF_INET, ip, &sin.sin_addr) == 1 {
                sin.sin_family = sa_family_t(AF_INET)
                sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.sin_port = port.bigEndian
                raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee = sin }
                return true
            }
            var sin6 = sockaddr_in6()
            if inet_pton(AF_INET6, ip, &sin6.sin6_addr) == 1 {
                sin6.sin6_family = sa_family_t(AF_INET6)
                sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sin6.sin6_port = port.bigEndian
                raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee = sin6 }
                return true
            }
            return false
        }
        guard ok else { return nil }
        storage = s
        family = Int32(s.ss_family)
    }

    var length: socklen_t {
        socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var s = storage
        return withUnsafePointer(to: &s) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) } }
    }

    /// Formats any IPv4/IPv6 `sockaddr` as a numeric string.
    static func string(from addr: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(addr.pointee.sa_family == sa_family_t(AF_INET6)
                            ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        // Link-local addresses come back with a %scope suffix; it isn't part of the address.
        return String(cString: host).split(separator: "%").first.map(String.init)
    }
}

/// Shares one unprivileged ICMP socket per address family (`SOCK_DGRAM` with
/// `IPPROTO_ICMP` / `IPPROTO_ICMPV6`) between every probe in the app. macOS allows these
/// without root and delivers Time Exceeded and Unreachable errors to them, which is all an
/// mtr-style hop trace needs.
///
/// Replies are matched to probes by (identifier, sequence); both families draw sequence
/// numbers from one counter. Sends run on one serial queue per family, so concurrent probes
/// with different TTLs don't race on the socket's hop limit, and a send that blocks in the
/// kernel can't tie up Swift's cooperative threads or the other family.
final class Pinger: @unchecked Sendable {
    static let shared = Pinger()

    private struct Pending {
        let sentAt: UInt64
        let continuation: CheckedContinuation<ProbeResult, Never>
    }

    private let fd4: Int32
    private let fd6: Int32
    private let identifier = UInt16(truncatingIfNeeded: getpid())
    private let lock = NSLock()          // guards nextSequence, pending and routeCache
    private let sendQueue4 = DispatchQueue(label: "NetMon.ICMP.send.v4", qos: .userInitiated)
    private let sendQueue6 = DispatchQueue(label: "NetMon.ICMP.send.v6", qos: .userInitiated)
    /// Whether each IPv6 destination had a route, and when that was checked.
    private var routeCache: [String: (ok: Bool, at: Date)] = [:]
    private var nextSequence: UInt16 = 0
    private var pending: [UInt16: Pending] = [:]

    private init() {
        fd4 = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        fd6 = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        for (fd, family) in [(fd4, IPFamily.v4), (fd6, .v6)] {
            if fd < 0 {
                NSLog("NetMon: could not open \(family.label) ICMP socket (errno \(errno))")
                continue
            }
            let thread = Thread { [unowned self] in self.receiveLoop(fd, family) }
            thread.name = "NetMon.ICMP.receive.\(family.rawValue)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Sends one echo request to `address` (numeric IPv4 or IPv6) with the given TTL / hop limit.
    func probe(_ address: String, ttl: Int = 64, timeout: TimeInterval = 2.0) async -> ProbeResult {
        guard let dst = SocketAddress(address, port: 0) else {
            return ProbeResult(kind: .sendFailed, responder: nil, rtt: nil)
        }
        let v6 = dst.family == AF_INET6
        let fd = v6 ? fd6 : fd4
        guard fd >= 0 else { return ProbeResult(kind: .sendFailed, responder: nil, rtt: nil) }
        // With no IPv6 route, macOS answers our sends with local Unreachable errors and,
        // while the receive thread is waiting, starts blocking sendto after a dozen or so.
        if v6, !hasRoute(address) { return ProbeResult(kind: .sendFailed, responder: nil, rtt: nil) }

        return await withCheckedContinuation { continuation in
            lock.lock()
            nextSequence &+= 1
            let seq = nextSequence
            pending[seq] = Pending(sentAt: DispatchTime.now().uptimeNanoseconds, continuation: continuation)
            lock.unlock()

            let packet = Self.echoRequest(v6: v6, identifier: identifier, sequence: seq)
            (v6 ? sendQueue6 : sendQueue4).async { [self] in
                var t = Int32(ttl)
                if v6 {
                    setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &t, socklen_t(MemoryLayout<Int32>.size))
                } else {
                    setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(MemoryLayout<Int32>.size))
                }
                let sent = dst.withSockaddr { sendto(fd, packet, packet.count, MSG_DONTWAIT, $0, $1) }
                if sent < 0 { complete(seq, with: ProbeResult(kind: .sendFailed, responder: nil, rtt: nil)) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.complete(seq, with: ProbeResult(kind: .timeout, responder: nil, rtt: nil))
            }
        }
    }

    /// Whether the system has a route to an IPv6 address, re-checked at most every 5 s.
    private func hasRoute(_ address: String) -> Bool {
        lock.lock()
        let cached = routeCache[address]
        lock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < 5 { return cached.ok }
        // A global destination needs a global source: a unique-local or link-local address
        // (common before an ISP turns IPv6 on) has no way out to the internet.
        let ok = Resolver.sourceAddress(toward: address).map { source in
            source != "::" && (!Resolver.isGlobalUnicast(address) || Resolver.isGlobalUnicast(source))
        } ?? false
        lock.lock()
        routeCache[address] = (ok, Date())
        lock.unlock()
        return ok
    }

    private func complete(_ seq: UInt16, with result: ProbeResult) {
        lock.lock()
        let entry = pending.removeValue(forKey: seq)
        lock.unlock()
        entry?.continuation.resume(returning: result)
    }

    private func receiveLoop(_ fd: Int32, _ family: IPFamily) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if n <= 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                usleep(100_000)
                continue
            }
            let parsed = family == .v4 ? Self.parse4(buffer, length: n, identifier: identifier)
                                       : Self.parse6(buffer, length: n, identifier: identifier)
            guard let (kind, seq) = parsed else { continue }
            let responder = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketAddress.string(from: $0) }
            }

            lock.lock()
            let entry = pending.removeValue(forKey: seq)
            lock.unlock()
            guard let entry else { continue }
            let rtt = Double(now &- entry.sentAt) / 1_000_000
            entry.continuation.resume(returning: ProbeResult(kind: kind, responder: responder, rtt: rtt))
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }

    /// Returns the probe sequence an ICMPv4 message belongs to, if it is one of ours.
    static func parse4(_ b: [UInt8], length n: Int, identifier: UInt16) -> (ProbeResult.Kind, UInt16)? {
        // macOS hands datagram ICMP sockets the IP header too. No ICMP type starts with
        // nibble 4, so a leading 0x4_ byte means an IPv4 header to skip.
        var off = 0
        if n >= 20, b[0] >> 4 == 4 { off = Int(b[0] & 0x0f) * 4 }
        guard n >= off + 8 else { return nil }

        switch b[off] {
        case 0: // echo reply
            guard u16(b, off + 4) == identifier else { return nil }
            return (.echoReply, u16(b, off + 6))
        case 11, 3: // time exceeded / destination unreachable: quotes our original packet
            let inner = off + 8
            guard n >= inner + 20 else { return nil }
            let innerICMP = inner + Int(b[inner] & 0x0f) * 4
            guard n >= innerICMP + 8, b[innerICMP] == 8, u16(b, innerICMP + 4) == identifier else { return nil }
            return (b[off] == 11 ? .timeExceeded : .unreachable, u16(b, innerICMP + 6))
        default:
            return nil
        }
    }

    /// Returns the probe sequence an ICMPv6 message belongs to, if it is one of ours.
    static func parse6(_ b: [UInt8], length n: Int, identifier: UInt16) -> (ProbeResult.Kind, UInt16)? {
        // ICMPv6 datagram sockets deliver just the ICMPv6 message (checked on macOS 26).
        // Skip an IPv6 header anyway if one ever appears: version nibble 6, next header 58.
        var off = 0
        if n >= 48, b[0] >> 4 == 6, b[6] == 58 { off = 40 }
        guard n >= off + 8 else { return nil }

        switch b[off] {
        case 129: // echo reply
            guard u16(b, off + 4) == identifier else { return nil }
            return (.echoReply, u16(b, off + 6))
        case 3, 1: // time exceeded / destination unreachable: 4 unused bytes, then our packet
            let inner = off + 8
            // Our echo request follows the quoted 40-byte IPv6 header directly (next header 58).
            guard n >= inner + 48, b[inner + 6] == 58 else { return nil }
            let innerICMP = inner + 40
            guard b[innerICMP] == 128, u16(b, innerICMP + 4) == identifier else { return nil }
            return (b[off] == 3 ? .timeExceeded : .unreachable, u16(b, innerICMP + 6))
        default:
            // Includes 128: on loopback the socket also sees our own echo requests.
            return nil
        }
    }

    private static func echoRequest(v6: Bool, identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var p: [UInt8] = [v6 ? 128 : 8, 0, 0, 0,
                          UInt8(identifier >> 8), UInt8(identifier & 0xff),
                          UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        p += [UInt8](repeating: 0x42, count: 48)
        // The kernel fills in the ICMPv6 checksum (it covers a pseudo-header we can't see).
        guard !v6 else { return p }
        let sum = checksum(p)
        p[2] = UInt8(sum >> 8)
        p[3] = UInt8(sum & 0xff)
        return p
    }

    private static func checksum(_ b: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < b.count { sum += UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
        if i < b.count { sum += UInt32(b[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

/// Resolves hostnames to addresses and addresses back to names, caching reverse lookups.
enum Resolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reverseCache: [String: String] = [:]

    /// The first address of `family` for `host`; a numeric address of that family is returned as is.
    static func address(for host: String, family: IPFamily) -> String? {
        if let literal = IPFamily(address: host) { return literal == family ? host : nil }
        var hints = addrinfo()
        hints.ai_family = family.addressFamily
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res, let addr = first.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(res) }
        return SocketAddress.string(from: addr)
    }

    static func cachedName(for ip: String) -> String? {
        lock.withLock { reverseCache[ip] }
    }

    /// Reverse-resolves `ip` off the main thread. Falls back to the IP itself.
    static func name(for ip: String) async -> String {
        if let cached = cachedName(for: ip) { return cached }
        let name = await Task.detached(priority: .utility) { () -> String in
            guard let addr = SocketAddress(ip, port: 0) else { return ip }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = addr.withSockaddr { getnameinfo($0, $1, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) }
            return rc == 0 ? String(cString: host) : ip
        }.value
        lock.withLock { reverseCache[ip] = name }
        return name
    }

    /// The local address the system would send from to reach `ip`, found by "connecting" a
    /// UDP socket (no packets are sent). Nil when there is no route. For IPv6, macOS can
    /// report "::" instead of failing when it has no IPv6 at all.
    static func sourceAddress(toward ip: String) -> String? {
        guard let dst = SocketAddress(ip, port: 53) else { return nil }
        let fd = socket(dst.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard dst.withSockaddr({ connect(fd, $0, $1) }) == 0 else { return nil }
        var local = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        return withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len) == 0 ? SocketAddress.string(from: $0) : nil
            }
        }
    }

    /// The local address and interface the system would use to reach `ip`. Nil when there is no route.
    static func route(toward ip: String) -> (localAddress: String, interface: String?)? {
        guard let dst = SocketAddress(ip, port: 53), let localIP = sourceAddress(toward: ip) else { return nil }

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return (localIP, nil) }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, Int32(addr.pointee.sa_family) == dst.family,
                  SocketAddress.string(from: addr) == localIP else { continue }
            return (localIP, String(cString: ifa.pointee.ifa_name))
        }
        return (localIP, nil)
    }

    /// Name of the interface traffic to `ip` leaves through, if it is a VPN tunnel.
    static func tunnelInterface(toward ip: String) -> String? {
        guard let name = route(toward: ip)?.interface else { return nil }
        return ["utun", "ipsec", "ppp", "tun", "wg"].contains { name.hasPrefix($0) } ? name : nil
    }

    /// True when the Mac has working global IPv6: a route to the internet from a global
    /// unicast (2000::/3) address. Probes Google's public resolver address; nothing is sent.
    /// (With no IPv6 at all, macOS still lets the UDP connect succeed, from "::".)
    static func hasGlobalIPv6() -> Bool {
        guard let local = route(toward: "2001:4860:4860::8888")?.localAddress else { return false }
        return isGlobalUnicast(local)
    }

    static func isGlobalUnicast(_ ip: String) -> Bool {
        var a = in6_addr()
        guard inet_pton(AF_INET6, ip, &a) == 1 else { return false }
        return a.__u6_addr.__u6_addr8.0 & 0xe0 == 0x20
    }

    /// True for private and link-local space: RFC 1918, CGNAT (100.64/10) and 169.254/16 for
    /// IPv4; unique-local (fc00::/7) and link-local (fe80::/10) for IPv6.
    static func isPrivate(_ ip: String) -> Bool {
        if ip.contains(":") {
            var a = in6_addr()
            guard inet_pton(AF_INET6, ip, &a) == 1 else { return false }
            let first = a.__u6_addr.__u6_addr8.0, second = a.__u6_addr.__u6_addr8.1
            return first & 0xfe == 0xfc || (first == 0xfe && second & 0xc0 == 0x80)
        }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}
