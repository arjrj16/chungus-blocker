import Foundation

final class ReelsBlockFilter: ConnectionFilter {

    private let sharedDefaults = UserDefaults(suiteName: BubbleConstants.appGroupID)

    var isEnabled: Bool {
        guard let defaults = sharedDefaults else { return true }
        // bool(forKey:) returns false when the key doesn't exist, not nil.
        // Use object(forKey:) to distinguish "key missing" from "key set to false".
        guard defaults.object(forKey: BubbleConstants.blockReelsEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: BubbleConstants.blockReelsEnabledKey)
    }

    // MARK: - Blocked CIDR ranges (Meta CDN IPs)
    // tun2socks resolves DNS before proxying, so we only ever see raw IPv4 addresses.
    // Domain-based filtering is not possible in this architecture.

    private struct CIDRRange {
        let base: UInt32
        let mask: UInt32

        init?(_ cidr: String) {
            let parts = cidr.split(separator: "/")
            guard parts.count == 2 else { return nil }
            let ipParts = parts[0].split(separator: ".").compactMap { UInt32($0) }
            guard ipParts.count == 4,
                  ipParts.allSatisfy({ $0 <= 255 }) else { return nil }
            guard let prefixLen = Int(parts[1]),
                  prefixLen >= 0, prefixLen <= 32 else { return nil }
            self.base = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
            self.mask = prefixLen == 0 ? 0 : ~UInt32(0) << (32 - prefixLen)
        }

        func contains(_ ip: UInt32) -> Bool {
            return (ip & mask) == (base & mask)
        }
    }

    private let blockedCIDRs: [CIDRRange] = [
        "157.240.0.0/16",   // Meta primary
        "31.13.64.0/18",    // Facebook CDN
        "69.171.224.0/19",  // Facebook CDN
        "69.63.176.0/20",   // Facebook
        "129.134.0.0/16",   // Meta
        "185.89.216.0/22",  // Meta
        "204.15.20.0/22",   // Instagram
        "66.220.144.0/20",  // Facebook
        "57.144.0.0/16",    // Meta CDN (Instagram video/reels)
    ].compactMap { CIDRRange($0) }

    // MARK: - ConnectionFilter

    func shouldAllow(host: String, port: UInt16) -> FilterDecision {
        guard isEnabled else { return .allow }

        if let ip = parseIPv4(host), isIPBlocked(ip) {
            return .block
        }

        return .allow
    }

    // MARK: - Private Helpers

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
