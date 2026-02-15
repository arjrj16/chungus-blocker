import Foundation
import Network
import os

// MARK: - Connection Filter Protocol

protocol ConnectionFilter {
    func shouldAllow(host: String, port: UInt16) -> FilterDecision
}

enum FilterDecision {
    case allow
    case block
}

// MARK: - SOCKS5 Errors

enum SOCKSError: Error, LocalizedError {
    case invalidPort(UInt16)
    case listenerFailed(Error)
    case connectionLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "Invalid SOCKS port: \(p)"
        case .listenerFailed(let e): return "Listener failed: \(e.localizedDescription)"
        case .connectionLimitReached: return "Maximum connection limit reached"
        }
    }
}

// MARK: - Parsed Address

private struct ParsedAddress {
    let host: String
    let port: UInt16
    let headerEndOffset: Int
}

// MARK: - SOCKS5 Proxy Server

final class SOCKSProxyServer {

    private var listener: NWListener?
    private let filter: ConnectionFilter
    private let queue = DispatchQueue(label: "com.arjun.chungus.socks5", qos: .userInitiated)
    private let log = TunnelLogger.shared
    private var connectionCount = 0

    // Thread-safe actual port (written on queue, read from outside)
    private let _actualPort = OSAllocatedUnfairLock(initialState: UInt16(0))
    var actualPort: UInt16 {
        _actualPort.withLock { $0 }
    }

    // Connection stats (queue-confined)
    private var statsAllowed = 0
    private var statsBlocked = 0
    private var statsUDP = 0
    private var statsErrors = 0
    private var statsTimer: DispatchSourceTimer?

    init(filter: ConnectionFilter) {
        self.filter = filter
    }

    // MARK: - Lifecycle

    func start(ready: @escaping (Error?) -> Void) {
        var didCallReady = false
        let callReady = { (error: Error?) in
            guard !didCallReady else { return }
            didCallReady = true
            ready(error)
        }

        let params = NWParameters.tcp
        guard let anyPort = NWEndpoint.Port(rawValue: 0) else {
            log.log("SOCKS5: Failed to create port 0 endpoint")
            callReady(SOCKSError.invalidPort(0))
            return
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(BubbleConstants.socksBindAddress),
            port: anyPort
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
                let port = listener.port?.rawValue ?? 0
                self._actualPort.withLock { $0 = port }
                self.log.log("SOCKS5: Listening on port \(port)")
                callReady(nil)
            case .waiting(let error):
                let port = listener.port?.rawValue ?? 0
                self._actualPort.withLock { $0 = port }
                self.log.log("SOCKS5: Listener waiting (\(error)), port=\(port)")
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
        queue.sync {
            statsTimer?.cancel()
            statsTimer = nil
        }
        listener?.cancel()
        listener = nil
    }

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + BubbleConstants.statsInterval, repeating: BubbleConstants.statsInterval)
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

        if connectionCount > BubbleConstants.maxConnections {
            log.log("SOCKS5: Connection limit reached (\(BubbleConstants.maxConnections)), rejecting")
            statsErrors += 1
            client.cancel()
            return
        }

        let id = connectionCount
        client.start(queue: queue)
        readMethodNegotiation(client: client, id: id)
    }

    // MARK: - SOCKS5 Method Negotiation

    private func readMethodNegotiation(client: NWConnection, id: Int) {
        client.receive(minimumIncompleteLength: 3, maximumLength: 512) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                self?.log.log("SOCKS5 #\(id): Method negotiation failed: \(String(describing: error))")
                self?.statsErrors += 1
                client.cancel()
                return
            }

            let bytes = [UInt8](data)
            guard bytes.count >= 3, bytes[0] == 0x05 else {
                self.log.log("SOCKS5 #\(id): Invalid SOCKS version or short handshake (\(bytes.count) bytes)")
                self.statsErrors += 1
                client.cancel()
                return
            }

            let nmethods = Int(bytes[1])
            let handshakeLen = 2 + nmethods
            let excess: Data? = bytes.count > handshakeLen ? Data(bytes[handshakeLen...]) : nil

            let reply = Data([0x05, 0x00])
            client.send(content: reply, completion: .contentProcessed { error in
                if error != nil {
                    self.log.log("SOCKS5 #\(id): Failed to send method reply: \(String(describing: error))")
                    self.statsErrors += 1
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
                self?.log.log("SOCKS5 #\(id): Request read failed: \(String(describing: error))")
                self?.statsErrors += 1
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
            log.log("SOCKS5 #\(id): Invalid request (ver=\(bytes.first.map(String.init) ?? "nil"), len=\(bytes.count))")
            client.cancel()
            return
        }

        let cmd = bytes[1]
        let atyp = bytes[3]

        // Parse address using shared helper (ATYP is at byte index 3)
        guard let addr = parseSOCKSAddress(from: bytes, atypOffset: 3) else {
            self.statsErrors += 1
            log.log("SOCKS5 #\(id): Failed to parse destination address")
            self.sendSocksError(client: client, reply: 0x08)
            return
        }

        // Diagnostic: log ATYP so we know if tun2socks sends domains or IPs
        let atypName: String
        switch atyp {
        case 0x01: atypName = "IPv4"
        case 0x03: atypName = "DOMAIN"
        case 0x04: atypName = "IPv6"
        default: atypName = "UNKNOWN(\(atyp))"
        }

        switch cmd {
        case 0x01: // CONNECT (TCP)
            log.log("TCP #\(id): CONNECT atyp=\(atypName) host=\(addr.host) port=\(addr.port)")
            handleConnect(client: client, id: id, host: addr.host, port: addr.port)

        case 0x05: // FWD_UDP (hev-socks5-tunnel custom extension)
            handleFwdUDP(client: client, id: id)

        default:
            self.statsErrors += 1
            log.log("SOCKS5 #\(id): unsupported cmd=\(cmd)")
            self.sendSocksError(client: client, reply: 0x07)
        }
    }

    // MARK: - Shared Address Parser

    /// Parses ATYP + address + port from a byte buffer.
    /// `atypOffset` is the index of the ATYP byte in the buffer.
    /// Returns nil if the buffer is too short or address type is unknown.
    private func parseSOCKSAddress(from bytes: [UInt8], atypOffset: Int) -> ParsedAddress? {
        guard bytes.count > atypOffset else { return nil }
        let atyp = bytes[atypOffset]
        let addrStart = atypOffset + 1

        switch atyp {
        case 0x01: // IPv4
            guard bytes.count >= addrStart + 4 + 2 else { return nil }
            let host = "\(bytes[addrStart]).\(bytes[addrStart + 1]).\(bytes[addrStart + 2]).\(bytes[addrStart + 3])"
            let portOffset = addrStart + 4
            let port = (UInt16(bytes[portOffset]) << 8) | UInt16(bytes[portOffset + 1])
            return ParsedAddress(host: host, port: port, headerEndOffset: portOffset + 2)

        case 0x03: // Domain name
            guard bytes.count > addrStart else { return nil }
            let domainLen = Int(bytes[addrStart])
            let domainStart = addrStart + 1
            guard bytes.count >= domainStart + domainLen + 2 else { return nil }
            guard let domain = String(bytes: Array(bytes[domainStart..<(domainStart + domainLen)]), encoding: .utf8) else {
                return nil
            }
            let portOffset = domainStart + domainLen
            let port = (UInt16(bytes[portOffset]) << 8) | UInt16(bytes[portOffset + 1])
            return ParsedAddress(host: domain, port: port, headerEndOffset: portOffset + 2)

        case 0x04: // IPv6
            guard bytes.count >= addrStart + 16 + 2 else { return nil }
            let parts = (0..<8).map { i in
                String(format: "%02x%02x", bytes[addrStart + i * 2], bytes[addrStart + i * 2 + 1])
            }
            let host = parts.joined(separator: ":")
            let portOffset = addrStart + 16
            let port = (UInt16(bytes[portOffset]) << 8) | UInt16(bytes[portOffset + 1])
            return ParsedAddress(host: host, port: port, headerEndOffset: portOffset + 2)

        default:
            return nil
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
                self?.log.log("UDP #\(id): Failed to send FWD_UDP reply: \(String(describing: error))")
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

            guard frameLen > 0, frameLen <= BubbleConstants.maxUDPFrameSize else {
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
                self.log.log("UDP #\(id): frame data read failed: \(String(describing: error))")
                client.cancel()
                return
            }

            let bytes = [UInt8](data)

            #if DEBUG
            let hexPrefix = bytes.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
            self.log.log("UDP #\(id): frame data (\(bytes.count)B): \(hexPrefix)")
            #endif

            // hev-socks5 FWD_UDP frame format:
            //   [1 byte][ATYP(1)][ADDR(var)][PORT(2)][payload]
            // ATYP is at byte 1
            guard let addr = self.parseSOCKSAddress(from: bytes, atypOffset: 1) else {
                self.log.log("UDP #\(id): failed to parse UDP frame address")
                self.readUDPFrameLength(client: client, id: id)
                return
            }

            let headerBytes = Array(bytes[0..<addr.headerEndOffset])
            let payload = addr.headerEndOffset < bytes.count ? Data(bytes[addr.headerEndOffset...]) : Data()

            self.statsUDP += 1
            self.log.log("UDP #\(id): dest=\(addr.host):\(addr.port), payload=\(payload.count)B")

            // Apply filter to UDP destinations too
            let decision = self.filter.shouldAllow(host: addr.host, port: addr.port)
            if decision == .block {
                self.statsBlocked += 1
                self.readUDPFrameLength(client: client, id: id)
                return
            }

            self.relayUDPDatagram(client: client, id: id, host: addr.host, port: addr.port,
                                   payload: payload, headerBytes: headerBytes)
        }
    }

    private func relayUDPDatagram(client: NWConnection, id: Int, host: String, port: UInt16,
                                   payload: Data, headerBytes: [UInt8]) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            self.log.log("UDP #\(id): invalid port \(port)")
            self.statsErrors += 1
            self.readUDPFrameLength(client: client, id: id)
            return
        }

        let udp = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)

        // Guard against double-continuation from timeout vs completion race
        var completed = false
        let complete: (Data?) -> Void = { [weak self] responseFrame in
            self?.queue.async {
                guard let self = self, !completed else { return }
                completed = true
                udp.cancel()

                if let frame = responseFrame {
                    client.send(content: frame, completion: .contentProcessed { _ in
                        self.readUDPFrameLength(client: client, id: id)
                    })
                } else {
                    self.readUDPFrameLength(client: client, id: id)
                }
            }
        }

        // UDP response timeout
        queue.asyncAfter(deadline: .now() + BubbleConstants.udpRelayTimeout) { [weak self] in
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

                    udp.receiveMessage { respData, context, isComplete, recvError in
                        if let respData = respData, !respData.isEmpty {
                            self?.log.log("UDP #\(id): got \(respData.count)B response from \(host):\(port)")
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
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            self.log.log("SOCKS5 #\(id): invalid port \(port)")
            self.statsErrors += 1
            self.sendSocksError(client: client, reply: 0x05)
            return
        }

        let target = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        // Track bytes for diagnostic logging
        let tracker = RelayTracker(id: id, host: host, port: port)

        // TCP relay timeout — cancel both sides if idle too long
        let timeout = DispatchWorkItem { [weak self] in
            self?.log.log("SOCKS5 #\(id): relay timeout to \(host):\(port)")
            self?.logRelayEnd(tracker: tracker, reason: "timeout")
            client.cancel()
            target.cancel()
        }
        queue.asyncAfter(deadline: .now() + BubbleConstants.tcpRelayTimeout, execute: timeout)

        target.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let reply = self.buildSocksReply(reply: 0x00, atyp: 0x01, addr: [0, 0, 0, 0], port: 0)
                client.send(content: reply, completion: .contentProcessed { error in
                    if error != nil {
                        timeout.cancel()
                        self.logRelayEnd(tracker: tracker, reason: "send-error")
                        client.cancel()
                        target.cancel()
                        return
                    }
                    self.relay(from: client, to: target, tracker: tracker, direction: .upload)
                    self.relay(from: target, to: client, tracker: tracker, direction: .download)
                })

            case .failed(let error):
                timeout.cancel()
                self.log.log("SOCKS5 #\(id): target failed \(host):\(port) — \(error)")
                self.statsErrors += 1
                self.logRelayEnd(tracker: tracker, reason: "target-failed")
                self.sendSocksError(client: client, reply: 0x05)
                target.cancel()

            case .cancelled:
                timeout.cancel()
                self.logRelayEnd(tracker: tracker, reason: "cancelled")
                client.cancel()

            default:
                break
            }
        }

        target.start(queue: queue)
    }

    // MARK: - Relay Byte Tracking

    private enum RelayDirection {
        case upload
        case download
    }

    private class RelayTracker {
        let id: Int
        let host: String
        let port: UInt16
        let startTime = Date()
        var bytesUp: Int = 0
        var bytesDown: Int = 0
        var logged = false

        init(id: Int, host: String, port: UInt16) {
            self.id = id
            self.host = host
            self.port = port
        }
    }

    private func logRelayEnd(tracker: RelayTracker, reason: String) {
        guard !tracker.logged else { return }
        tracker.logged = true
        let duration = String(format: "%.1f", Date().timeIntervalSince(tracker.startTime))
        let totalBytes = tracker.bytesUp + tracker.bytesDown
        log.log("RELAY #\(tracker.id): \(tracker.host):\(tracker.port) — \(reason) — \(duration)s — up:\(tracker.bytesUp)B down:\(tracker.bytesDown)B total:\(totalBytes)B")
    }

    // MARK: - Bidirectional Relay

    private func relay(from source: NWConnection, to destination: NWConnection, tracker: RelayTracker, direction: RelayDirection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: BubbleConstants.relayBufferSize) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                switch direction {
                case .upload: tracker.bytesUp += data.count
                case .download: tracker.bytesDown += data.count
                }
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        self.logRelayEnd(tracker: tracker, reason: "relay-error")
                        source.cancel()
                        destination.cancel()
                        return
                    }
                    if isComplete {
                        self.logRelayEnd(tracker: tracker, reason: "complete")
                        source.cancel()
                        destination.cancel()
                    } else {
                        self.relay(from: source, to: destination, tracker: tracker, direction: direction)
                    }
                })
            } else if isComplete || error != nil {
                self.logRelayEnd(tracker: tracker, reason: isComplete ? "complete" : "error")
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
