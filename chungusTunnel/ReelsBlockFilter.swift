import Foundation

final class ReelsBlockFilter: ConnectionFilter {

    private let sharedDefaults = UserDefaults(suiteName: "group.com.arjun.chungus")

    var isEnabled: Bool {
        sharedDefaults?.bool(forKey: "blockReelsEnabled") ?? true
    }

    // MARK: - Allowlist (always pass through even when filtering is on)
    // These are Instagram's API/messaging endpoints — blocking them breaks DMs, login, etc.

    private let allowedDomains: Set<String> = [
        "i.instagram.com",
        "graph.instagram.com",
        "mqtt-mini.facebook.com",
        "edge-mqtt.facebook.com",
        "b-api.facebook.com",
        "api.instagram.com",
        "gateway.instagram.com",
    ]

    // MARK: - Blocked domain patterns (CDN domains that serve Reels video)

    private let blockedDomainSuffixes: [String] = [
        ".cdninstagram.com",
        ".fbcdn.net",
    ]

    private let blockedDomainPrefixes: [String] = [
        "scontent",
        "video",
    ]

    // MARK: - Blocked CIDR ranges (Meta CDN IPs)
    // These are Meta's well-known CDN ranges that serve video content

    private struct CIDRRange {
        let base: UInt32
        let mask: UInt32

        init(_ cidr: String) {
            let parts = cidr.split(separator: "/")
            let ipParts = parts[0].split(separator: ".").map { UInt32($0)! }
            let prefixLen = Int(parts[1])!
            self.base = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
            self.mask = prefixLen == 0 ? 0 : ~UInt32(0) << (32 - prefixLen)
        }

        func contains(_ ip: UInt32) -> Bool {
            return (ip & mask) == (base & mask)
        }
    }

    private let blockedCIDRs: [CIDRRange] = [
        CIDRRange("157.240.0.0/16"),   // Meta primary
        CIDRRange("31.13.64.0/18"),     // Facebook CDN
        CIDRRange("69.171.224.0/19"),   // Facebook CDN
        CIDRRange("69.63.176.0/20"),    // Facebook
        CIDRRange("129.134.0.0/16"),    // Meta
        CIDRRange("185.89.216.0/22"),   // Meta
        CIDRRange("204.15.20.0/22"),    // Instagram
        CIDRRange("66.220.144.0/20"),   // Facebook
    ]

    // MARK: - ConnectionFilter

    func shouldAllow(host: String, port: UInt16) -> FilterDecision {
        guard isEnabled else { return .allow }

        // Always allow explicitly allowlisted domains
        if allowedDomains.contains(host) {
            return .allow
        }

        // Check domain-based blocking
        if isDomainBlocked(host) {
            return .block
        }

        // Check IP-based blocking
        if let ip = parseIPv4(host), isIPBlocked(ip) {
            return .block
        }

        // Default: allow everything else
        return .allow
    }

    // MARK: - Private Helpers

    private func isDomainBlocked(_ host: String) -> Bool {
        let lower = host.lowercased()

        for suffix in blockedDomainSuffixes {
            if lower.hasSuffix(suffix) {
                return true
            }
        }

        for prefix in blockedDomainPrefixes {
            if lower.hasPrefix(prefix) {
                return true
            }
        }

        return false
    }

    private func parseIPv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        guard let a = UInt32(parts[0]), let b = UInt32(parts[1]),
              let c = UInt32(parts[2]), let d = UInt32(parts[3]),
              a <= 255, b <= 255, c <= 255, d <= 255 else { return nil }
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    private func isIPBlocked(_ ip: UInt32) -> Bool {
        for cidr in blockedCIDRs {
            if cidr.contains(ip) {
                return true
            }
        }
        return false
    }
}
