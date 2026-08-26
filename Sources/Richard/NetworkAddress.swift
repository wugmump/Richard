import Foundation

/// Chooses a reachable host name/address for remote chat links.
enum NetworkAddress {
    /// Prefers a private LAN IPv4 address so office users can open Richard from
    /// another machine. Falls back to Bonjour `.local` hostname when no private
    /// address is visible.
    static func shareHost() -> String {
        primaryIPv4Address() ?? localHostname()
    }

    /// Scans active non-loopback IPv4 interfaces and returns the first private
    /// address. Private addresses are more reliable for simple LAN sharing than
    /// whatever hostname DNS happens to resolve.
    private static func primaryIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        // `getifaddrs` returns a linked list owned by the C API; Swift's
        // `sequence(first:next:)` gives a readable way to traverse it.
        for pointer in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            guard isUp, !isLoopback, interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            // Convert the socket address to a numeric IPv4 string without
            // triggering reverse DNS lookup.
            var address = interface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                let nameBytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let value = String(decoding: nameBytes, as: UTF8.self)
                // Keep the URL office-local. Public/routable addresses are not
                // useful here because the server only listens on this Mac.
                if value.hasPrefix("10.") || value.hasPrefix("172.") || value.hasPrefix("192.168.") {
                    return value
                }
            }
        }

        return nil
    }

    /// Returns the Mac's Bonjour hostname as a final share-link fallback.
    private static func localHostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let nameBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let name = String(decoding: nameBytes, as: UTF8.self)
            return name.hasSuffix(".local") ? name : "\(name).local"
        }
        return "localhost"
    }
}
