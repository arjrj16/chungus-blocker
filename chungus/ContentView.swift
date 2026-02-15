import SwiftUI
import NetworkExtension

struct ContentView: View {
    @State private var vpnStatus: NEVPNStatus = .disconnected
    @State private var manager: NETunnelProviderManager?
    @State private var statusLog: [String] = []
    @State private var tunnelLog: String = "(no logs yet)"
    @State private var showLog = false

    @AppStorage("blockReelsEnabled", store: UserDefaults(suiteName: "group.com.arjun.chungus"))
    private var blockReelsEnabled: Bool = true

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Status icon
                Image(systemName: vpnStatus == .connected ? "shield.fill" : "shield.slash.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundColor(vpnStatus == .connected ? .green : .gray)

                VStack(spacing: 5) {
                    Text("bubble")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                    Text("by arj")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                // VPN toggle button
                Button(action: { toggleVPN() }) {
                    Text(vpnStatus == .connected ? "STOP bubs" : "START bubs")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(vpnStatus == .connected ? Color.red : Color.blue)
                        .cornerRadius(15)
                        .shadow(radius: 5)
                }
                .padding(.horizontal, 40)

                Toggle("Block Reels", isOn: $blockReelsEnabled)
                    .padding(.horizontal, 40)

                // Status with color coding
                HStack {
                    Circle()
                        .fill(statusColor(for: vpnStatus))
                        .frame(width: 10, height: 10)
                    Text("Status: \(statusString(for: vpnStatus))")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                // App-side status log (most recent on top)
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Log:")
                        .font(.caption.bold())
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(statusLog.reversed(), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding(.horizontal)

                // Tunnel extension log viewer button
                Button("Show Extension Log") {
                    refreshTunnelLog()
                    showLog = true
                }
                .font(.caption)

                Button("Refresh Extension Log") {
                    refreshTunnelLog()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .sheet(isPresented: $showLog) {
                NavigationView {
                    ScrollView {
                        Text(tunnelLog)
                            .font(.system(size: 10, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .navigationTitle("Extension Log")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLog = false }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            HStack {
                                Button("Copy") {
                                    UIPasteboard.general.string = tunnelLog
                                }
                                Button("Refresh") { refreshTunnelLog() }
                            }
                        }
                    }
                }
            }
            .onAppear {
                appendLog("App launched")
                setupVPN()
            }
        }
    }

    // MARK: - Helpers

    func appendLog(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        statusLog.append("[\(ts)] \(msg)")
    }

    func refreshTunnelLog() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.arjun.chungus") else {
            tunnelLog = "ERROR: Can't access app group container"
            appendLog("ERROR: No app group container")
            return
        }
        let fileURL = container.appendingPathComponent("tunnel_log.txt")
        if let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty {
            tunnelLog = content
        } else {
            tunnelLog = "(no extension logs found at \(fileURL.path))"
        }
    }

    func statusColor(for status: NEVPNStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting, .reasserting: return .orange
        case .disconnecting: return .yellow
        default: return .red
        }
    }

    // MARK: - VPN Setup

    func setupVPN() {
        appendLog("Loading VPN preferences...")
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                appendLog("ERROR loading prefs: \(error.localizedDescription)")
                return
            }

            if let existingManagers = managers, !existingManagers.isEmpty {
                let mgr = existingManagers[0]
                self.manager = mgr
                self.vpnStatus = mgr.connection.status
                appendLog("Found existing profile. Status: \(statusString(for: mgr.connection.status))")
                appendLog("Bundle ID: \((mgr.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "nil")")

                // Observe VPN status changes in real time
                NotificationCenter.default.addObserver(
                    forName: .NEVPNStatusDidChange,
                    object: mgr.connection,
                    queue: .main
                ) { _ in
                    let newStatus = mgr.connection.status
                    self.vpnStatus = newStatus
                    appendLog("VPN status -> \(statusString(for: newStatus))")

                    // Auto-refresh extension log on status changes
                    if newStatus == .connected || newStatus == .disconnected {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            refreshTunnelLog()
                        }
                    }
                }
            } else {
                appendLog("No VPN profile found, creating one...")
                let newManager = NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = "com.arjun.chungus.chungusTunnel"
                proto.serverAddress = "bubble"
                newManager.protocolConfiguration = proto
                newManager.localizedDescription = "Bubble Blocker"

                newManager.saveToPreferences { error in
                    if let error = error {
                        appendLog("ERROR saving profile: \(error.localizedDescription)")
                        return
                    }
                    appendLog("Profile saved. Reloading...")
                    self.setupVPN()
                }
            }
        }
    }

    func toggleVPN() {
        guard let manager = self.manager else {
            appendLog("ERROR: Manager not ready")
            return
        }

        appendLog("Toggle VPN: current status = \(statusString(for: manager.connection.status))")

        manager.loadFromPreferences { error in
            if let error = error {
                appendLog("ERROR loading: \(error.localizedDescription)")
                return
            }

            manager.isEnabled = true

            manager.saveToPreferences { error in
                if let error = error {
                    appendLog("ERROR saving: \(error.localizedDescription)")
                    return
                }

                do {
                    if manager.connection.status == .connected {
                        appendLog("Stopping VPN tunnel...")
                        manager.connection.stopVPNTunnel()
                    } else {
                        appendLog("Starting VPN tunnel...")
                        try manager.connection.startVPNTunnel()
                        appendLog("startVPNTunnel() called successfully (no throw)")
                    }
                } catch {
                    appendLog("ERROR toggling: \(error.localizedDescription)")
                    appendLog("Error details: \((error as NSError).domain) code \((error as NSError).code)")
                }
            }
        }
    }

    func statusString(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "Invalid"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reasserting: return "Reasserting..."
        case .disconnecting: return "Disconnecting..."
        @unknown default: return "Unknown"
        }
    }
}

#Preview {
    ContentView()
}
