// NetworkUtils.swift
// MacLink – macOS Host + iOS Client
// Network address discovery utilities.

import Foundation
import SystemConfiguration
#if os(macOS)
import AppKit
#endif

public struct NetworkUtils {

    /// Returns the Mac's IPv4 address on the local network (Wi-Fi / Ethernet).
    /// Prefers en0, then other en* interfaces. Never returns VPN (utun), Tailscale (100.x)
    /// or link-local addresses, which a phone on the same Wi-Fi cannot reach.
    public static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, ip: String)] = []
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi-Fi / Ethernet / USB-Ethernet only

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            if ip.hasPrefix("169.254") || isTailscaleIP(ip) { continue }
            candidates.append((name, ip))
        }
        if let en0 = candidates.first(where: { $0.name == "en0" }) { return en0.ip }
        return candidates.first?.ip
    }

    /// Bonjour hostname (e.g. "My-MacBook-Pro.local"). Resolvable by iPhones/Android
    /// on the same Wi-Fi and stays the same when the router hands out a new IP.
    public static func localHostName() -> String? {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return "\(name).local"
        }
        return nil
    }

    /// Tailscale MagicDNS name (e.g. "my-mac.tailnet.ts.net"). Never changes, works from any
    /// network while Tailscale is on in the phone. Blocking – call off the main thread.
    public static func tailscaleDNSName() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                          "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["status", "--json", "--peers=false"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["BackendState"] as? String) == "Running",
              let me = json["Self"] as? [String: Any],
              var name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// Tailscale uses the CGNAT range 100.64.0.0/10.
    static func isTailscaleIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
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
                    if isTailscaleIP(ip) { return ip }
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
