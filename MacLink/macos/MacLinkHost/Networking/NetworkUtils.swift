// NetworkUtils.swift
// MacLink – macOS Host + iOS Client
// Network address discovery utilities.

import Foundation
#if os(macOS)
import AppKit
#endif

public struct NetworkUtils {

    /// Returns the primary non-loopback IPv4 address of the local machine.
    public static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp       = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isRunning  = (flags & IFF_RUNNING) != 0

            if isUp && isRunning && !isLoopback {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(current.pointee.ifa_addr.pointee.sa_len)
                if getnameinfo(current.pointee.ifa_addr, saLen,
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ipString = String(cString: hostname)
                    // Prefer en0-style addresses; skip link-local
                    if !ipString.hasPrefix("169.254") && ipString.contains(".") {
                        address = ipString
                        if String(cString: current.pointee.ifa_name) == "en0" { break }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return address
    }

    /// Returns the Tailscale IPv4 address (100.x.x.x range) if the daemon is running.
    public static func tailscaleIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            // Tailscale uses the "utun" interface family on macOS
            // and the Tailscale 100.x.x.x range
            if name.hasPrefix("utun") || name == "ts0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(current.pointee.ifa_addr.pointee.sa_len)
                if getnameinfo(current.pointee.ifa_addr, saLen,
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if ip.hasPrefix("100.") { return ip }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    /// Resolves a MagicDNS hostname to an IPv4 address (synchronous, for diagnostic use).
    public static func resolve(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family   = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0,
              let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var hostname = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &hostname, socklen_t(hostname.count))
        return String(cString: hostname)
    }
}
