import Foundation
import Network

// MARK: - Connection Filter Protocol

protocol ConnectionFilter {
    func shouldAllow(host: String, port: UInt16) -> FilterDecision
}

enum FilterDecision {
    case allow
    case block
}

// MARK: - SOCKS5 Proxy Server

final class SOCKSProxyServer {

    private var listener: NWListener?
    /// The actual port the listener bound to (available after `start` callback fires).
    private(set) var actualPort: UInt16 = 0
    private let filter: ConnectionFilter
    private let queue = DispatchQueue(label: "com.arjun.chungus.socks5", qos: .userInitiated)
    private let log = TunnelLogger.shared
    private var connectionCount = 0

    // Connection stats (logged periodically instead of per-connection)
    private var statsAllowed = 0
    private var statsBlocked = 0
    private var statsUDP = 0
    private var statsErrors = 0
    private var statsTimer: DispatchSourceTimer?

    init(filter: ConnectionFilter) {
        self.filter = filter
    }

    /// Starts the listener on any available port. Calls `ready` exactly once.
    /// After `ready(nil)`, read `actualPort` to get the assigned port.
    func start(ready: @escaping (Error?) -> Void) {
        var didCallReady = false
        let callReady = { (error: Error?) in
            guard !didCallReady else { return }
            didCallReady = true
            ready(error)
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 0)!
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            log.log("SOCKS5: Failed to create listener: \(error)")
            callReady(error)
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.actualPort = listener.port?.rawValue ?? 0
                self.log.log("SOCKS5: Listening on port \(self.actualPort)")
                callReady(nil)
            case .waiting(let error):
                self.actualPort = listener.port?.rawValue ?? 0
                self.log.log("SOCKS5: Listener waiting (\(error)), port=\(self.actualPort)")
                callReady(nil)
            case .failed(let error):
                self.log.log("SOCKS5: Listener failed: \(error)")
                callReady(error)
            case .cancelled:
                self.log.log("SOCKS5: Listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: queue)
        startStatsTimer()
    }

    func stop() {
        statsTimer?.cancel()
        statsTimer = nil
        listener?.cancel()
        listener = nil
    }

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let total = self.connectionCount
            guard total > 0 else { return }
            self.log.log("SOCKS5 STATS: \(total) conns, \(self.statsAllowed) TCP allowed, \(self.statsBlocked) blocked, \(self.statsUDP) UDP relayed, \(self.statsErrors) errors")
        }
        timer.resume()
        statsTimer = timer
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ client: NWConnection) {
        connectionCount += 1
        let id = connectionCount
        client.start(queue: queue)
        readMethodNegotiation(client: client, id: id)
    }

    // MARK: - SOCKS5 Method Negotiation

    private func readMethodNegotiation(client: NWConnection, id: Int) {
        client.receive(minimumIncompleteLength: 3, maximumLength: 512) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                client.cancel()
                return
            }

            let bytes = [UInt8](data)
            guard bytes.count >= 3, bytes[0] == 0x05 else {
                client.cancel()
                return
            }

            let nmethods = Int(bytes[1])
            let handshakeLen = 2 + nmethods
            let excess: Data? = bytes.count > handshakeLen ? Data(bytes[handshakeLen...]) : nil

            let reply = Data([0x05, 0x00])
            client.send(content: reply, completion: .contentProcessed { error in
                if error != nil {
                    client.cancel()
                    return
                }
                self.readRequest(client: client, id: id, buffered: excess)
            })
        }
    }

    // MARK: - SOCKS5 Request (CONNECT / FWD_UDP)

    private func readRequest(client: NWConnection, id: Int, buffered: Data?) {
        if let buffered = buffered, buffered.count >= 4 {
            self.parseRequest(client: client, id: id, data: buffered)
            return
        }

        let existingBytes = buffered ?? Data()

        client.receive(minimumIncompleteLength: 4 - existingBytes.count, maximumLength: 512) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                client.cancel()
                return
            }
            self.parseRequest(client: client, id: id, data: existingBytes + data)
        }
    }

    private func parseRequest(client: NWConnection, id: Int, data: Data) {
        let bytes = [UInt8](data)

        guard bytes.count >= 4, bytes[0] == 0x05 else {
            self.statsErrors += 1
            client.cancel()
            return
        }

        let cmd = bytes[1]

        // Parse address (shared by CONNECT and FWD_UDP)
        let atyp = bytes[3]
        var host: String?
        var portOffset: Int = 0

        switch atyp {
        case 0x01: // IPv4
            guard bytes.count >= 10 else { client.cancel(); return }
            host = "\(bytes[4]).\(bytes[5]).\(bytes[6]).\(bytes[7])"
            portOffset = 8

        case 0x03: // Domain name
            guard bytes.count >= 5 else { client.cancel(); return }
            let domainLen = Int(bytes[4])
            guard bytes.count >= 5 + domainLen + 2 else { client.cancel(); return }
            host = String(bytes: Array(bytes[5..<(5 + domainLen)]), encoding: .utf8)
            portOffset = 5 + domainLen

        case 0x04: // IPv6
            guard bytes.count >= 22 else { client.cancel(); return }
            let ipv6Parts = (0..<8).map { i -> String in
                let hi = bytes[4 + i * 2]
                let lo = bytes[4 + i * 2 + 1]
                return String(format: "%02x%02x", hi, lo)
            }
            host = ipv6Parts.joined(separator: ":")
            portOffset = 20

        default:
            self.statsErrors += 1
            self.sendSocksError(client: client, reply: 0x08)
            return
        }

        guard let destHost = host, bytes.count >= portOffset + 2 else {
            self.statsErrors += 1
            client.cancel()
            return
        }

        let destPort = (UInt16(bytes[portOffset]) << 8) | UInt16(bytes[portOffset + 1])

        switch cmd {
        case 0x01: // CONNECT (TCP)
            handleConnect(client: client, id: id, host: destHost, port: destPort)

        case 0x05: // FWD_UDP (hev-socks5-tunnel custom extension)
            handleFwdUDP(client: client, id: id)

        default:
            self.statsErrors += 1
            log.log("SOCKS5 #\(id): unsupported cmd=\(cmd)")
            self.sendSocksError(client: client, reply: 0x07)
        }
    }

    // MARK: - CONNECT (TCP)

    private func handleConnect(client: NWConnection, id: Int, host: String, port: UInt16) {
        let decision = self.filter.shouldAllow(host: host, port: port)

        switch decision {
        case .block:
            self.statsBlocked += 1
            self.log.log("SOCKS5 #\(id): BLOCKED \(host):\(port)")
            self.sendSocksError(client: client, reply: 0x05)

        case .allow:
            self.statsAllowed += 1
            self.connectToTarget(client: client, host: host, port: port, id: id)
        }
    }

    // MARK: - FWD_UDP (hev-socks5-tunnel custom command 0x05)
    //
    // Protocol after SOCKS5 handshake + FWD_UDP accept:
    //   Each UDP datagram is framed over TCP as:
    //     [2-byte BE length N][N bytes of SOCKS5 UDP frame]
    //   Where the SOCKS5 UDP frame is:
    //     [RSV 2][FRAG 1][ATYP 1][DST.ADDR var][DST.PORT 2][UDP payload]

    private func handleFwdUDP(client: NWConnection, id: Int) {
        log.log("UDP #\(id): FWD_UDP accepted, starting frame relay")
        let reply = buildSocksReply(reply: 0x00, atyp: 0x01, addr: [0, 0, 0, 0], port: 0)
        client.send(content: reply, completion: .contentProcessed { [weak self] error in
            if error != nil {
                client.cancel()
                return
            }
            self?.readUDPFrameLength(client: client, id: id)
        })
    }

    private func readUDPFrameLength(client: NWConnection, id: Int) {
        client.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard let data = data, data.count >= 2, error == nil else {
                self.log.log("UDP #\(id): frame length read failed, isComplete=\(isComplete), error=\(String(describing: error))")
                client.cancel()
                return
            }

            let bytes = [UInt8](data)
            let frameLen = (Int(bytes[0]) << 8) | Int(bytes[1])
            self.log.log("UDP #\(id): frame length=\(frameLen)")

            // UDP datagrams can't exceed MTU (~9000). Anything larger is desync/garbage.
            guard frameLen > 0, frameLen <= 9000 else {
                self.log.log("UDP #\(id): invalid frame length \(frameLen), closing connection")
                client.cancel()
                return
            }

            self.readUDPFrameData(client: client, id: id, frameLen: frameLen)
        }
    }

    private func readUDPFrameData(client: NWConnection, id: Int, frameLen: Int) {
        client.receive(minimumIncompleteLength: frameLen, maximumLength: frameLen) { [weak self] data, _, _, error in
            guard let self = self else { return }
            guard let data = data, data.count >= frameLen, error == nil else {
                client.cancel()
                return
            }

            let bytes = [UInt8](data)
            let hexPrefix = bytes.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
            self.log.log("UDP #\(id): frame data (\(bytes.count)B): \(hexPrefix)")

            // hev-socks5 FWD_UDP frame format (NOT standard SOCKS5 UDP relay):
            //   [1 byte][ATYP(1)][ADDR(var)][PORT(2)][payload]
            // ATYP is at byte 1, not byte 3.
            guard bytes.count >= 4 else {
                self.readUDPFrameLength(client: client, id: id)
                return
            }

            let atyp = bytes[1]
            var host: String?
            var addrEnd: Int = 0

            switch atyp {
            case 0x01: // IPv4
                guard bytes.count >= 8 else { self.readUDPFrameLength(client: client, id: id); return }
                host = "\(bytes[2]).\(bytes[3]).\(bytes[4]).\(bytes[5])"
                addrEnd = 6

            case 0x03: // Domain
                guard bytes.count >= 3 else { self.readUDPFrameLength(client: client, id: id); return }
                let domLen = Int(bytes[2])
                guard bytes.count >= 3 + domLen + 2 else { self.readUDPFrameLength(client: client, id: id); return }
                host = String(bytes: Array(bytes[3..<(3 + domLen)]), encoding: .utf8)
                addrEnd = 3 + domLen

            case 0x04: // IPv6
                guard bytes.count >= 20 else { self.readUDPFrameLength(client: client, id: id); return }
                let parts = (0..<8).map { i in String(format: "%02x%02x", bytes[2 + i * 2], bytes[2 + i * 2 + 1]) }
                host = parts.joined(separator: ":")
                addrEnd = 18

            default:
                self.log.log("UDP #\(id): unknown ATYP=\(atyp) at byte[1], raw: \(hexPrefix)")
                self.readUDPFrameLength(client: client, id: id)
                return
            }

            guard let destHost = host, bytes.count >= addrEnd + 2 else {
                self.readUDPFrameLength(client: client, id: id)
                return
            }

            let destPort = (UInt16(bytes[addrEnd]) << 8) | UInt16(bytes[addrEnd + 1])
            let payloadStart = addrEnd + 2
            let payload = payloadStart < bytes.count ? Data(bytes[payloadStart...]) : Data()
            let headerBytes = Array(bytes[0..<payloadStart])

            self.statsUDP += 1
            self.log.log("UDP #\(id): dest=\(destHost):\(destPort), payload=\(payload.count)B, header=\(headerBytes.count)B")

            // Apply filter to UDP destinations too
            let decision = self.filter.shouldAllow(host: destHost, port: destPort)
            if decision == .block {
                self.statsBlocked += 1
                self.readUDPFrameLength(client: client, id: id)
                return
            }

            self.relayUDPDatagram(client: client, id: id, host: destHost, port: destPort,
                                   payload: payload, headerBytes: headerBytes)
        }
    }

    private func relayUDPDatagram(client: NWConnection, id: Int, host: String, port: UInt16,
                                   payload: Data, headerBytes: [UInt8]) {
        let udp = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )

        // Guard against double-continuation from timeout vs completion race
        var completed = false
        let complete: (Data?) -> Void = { [weak self] responseFrame in
            guard !completed else { return }
            completed = true
            udp.cancel()

            if let frame = responseFrame {
                client.send(content: frame, completion: .contentProcessed { _ in
                    self?.readUDPFrameLength(client: client, id: id)
                })
            } else {
                self?.readUDPFrameLength(client: client, id: id)
            }
        }

        // 5-second timeout for UDP response
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.log.log("UDP #\(id): TIMEOUT for \(host):\(port)")
            complete(nil)
        }

        udp.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log.log("UDP #\(id): NWConnection ready to \(host):\(port), sending \(payload.count)B")
                udp.send(content: payload, completion: .contentProcessed { error in
                    if let error = error {
                        self?.log.log("UDP #\(id): send FAILED to \(host):\(port): \(error)")
                        complete(nil)
                        return
                    }
                    self?.log.log("UDP #\(id): sent to \(host):\(port), waiting for response...")

                    udp.receiveMessage { respData, context, isComplete, recvError in
                        if let respData = respData, !respData.isEmpty {
                            self?.log.log("UDP #\(id): got \(respData.count)B response from \(host):\(port)")
                            // Build response: [2-byte len][SOCKS5 UDP header][response data]
                            var frame = headerBytes
                            frame.append(contentsOf: [UInt8](respData))
                            let frameLen = frame.count
                            var framedData: [UInt8] = [UInt8(frameLen >> 8), UInt8(frameLen & 0xFF)]
                            framedData.append(contentsOf: frame)
                            complete(Data(framedData))
                        } else {
                            self?.log.log("UDP #\(id): empty/nil response from \(host):\(port), error=\(String(describing: recvError))")
                            complete(nil)
                        }
                    }
                })

            case .failed(let error):
                self?.log.log("UDP #\(id): NWConnection FAILED to \(host):\(port): \(error)")
                complete(nil)

            case .waiting(let error):
                self?.log.log("UDP #\(id): NWConnection WAITING to \(host):\(port): \(error)")

            default:
                break
            }
        }

        udp.start(queue: queue)
    }

    // MARK: - Target Connection (TCP)

    private func connectToTarget(client: NWConnection, host: String, port: UInt16, id: Int) {
        let target = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        target.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let reply = self.buildSocksReply(reply: 0x00, atyp: 0x01, addr: [0, 0, 0, 0], port: 0)
                client.send(content: reply, completion: .contentProcessed { error in
                    if error != nil {
                        client.cancel()
                        target.cancel()
                        return
                    }
                    self.relay(from: client, to: target)
                    self.relay(from: target, to: client)
                })

            case .failed(let error):
                self.log.log("SOCKS5 #\(id): target failed \(host):\(port) — \(error)")
                self.statsErrors += 1
                self.sendSocksError(client: client, reply: 0x05)
                target.cancel()

            case .cancelled:
                client.cancel()

            default:
                break
            }
        }

        target.start(queue: queue)
    }

    // MARK: - Bidirectional Relay

    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        source.cancel()
                        destination.cancel()
                        return
                    }
                    if isComplete {
                        source.cancel()
                        destination.cancel()
                    } else {
                        self.relay(from: source, to: destination)
                    }
                })
            } else if isComplete || error != nil {
                source.cancel()
                destination.cancel()
            }
        }
    }

    // MARK: - SOCKS5 Reply Helpers

    private func sendSocksError(client: NWConnection, reply: UInt8) {
        let data = buildSocksReply(reply: reply, atyp: 0x01, addr: [0, 0, 0, 0], port: 0)
        client.send(content: data, completion: .contentProcessed { _ in
            client.cancel()
        })
    }

    private func buildSocksReply(reply: UInt8, atyp: UInt8, addr: [UInt8], port: UInt16) -> Data {
        var response: [UInt8] = [
            0x05,   // VER
            reply,  // REP
            0x00,   // RSV
            atyp    // ATYP
        ]
        response.append(contentsOf: addr)
        response.append(UInt8(port >> 8))
        response.append(UInt8(port & 0xFF))
        return Data(response)
    }
}
