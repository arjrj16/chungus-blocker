import Foundation

struct TrafficSnapshot: Codable {
    let timestamp: Date
    let connections: [ConnectionSnapshot]
    let stats: StatsSnapshot
    let topDomains: [DomainSnapshot]
}

struct ConnectionSnapshot: Codable, Identifiable {
    let id: Int
    let host: String
    let port: UInt16
    let sni: String?
    let startTime: Date
    let bytesUp: Int
    let bytesDown: Int
    let isActive: Bool

    var totalBytes: Int { bytesUp + bytesDown }
}

struct StatsSnapshot: Codable {
    let totalConns: Int
    let tcpAllowed: Int
    let tcpBlocked: Int
    let udpRelayed: Int
    let errors: Int
}

struct DomainSnapshot: Codable, Identifiable {
    var id: String { domain }
    let domain: String
    let count: Int
    let totalBytes: Int
}
