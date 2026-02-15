import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager()

    @AppStorage(BubbleConstants.blockReelsEnabledKey,
                store: UserDefaults(suiteName: BubbleConstants.appGroupID))
    private var blockReelsEnabled: Bool = true

    @State private var showLog = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Status icon
                Image(systemName: vpnManager.vpnStatus == .connected ? "shield.fill" : "shield.slash.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundColor(vpnManager.vpnStatus == .connected ? .green : .gray)

                VStack(spacing: 5) {
                    Text("bubble")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                    Text("by arj")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                // VPN toggle button
                Button(action: { vpnManager.toggleVPN() }) {
                    Text(vpnManager.vpnStatus == .connected ? "STOP bubs" : "START bubs")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(vpnManager.vpnStatus == .connected ? Color.red : Color.blue)
                        .cornerRadius(15)
                        .shadow(radius: 5)
                }
                .padding(.horizontal, 40)

                NavigationLink {
                    TrafficDashboardView()
                } label: {
                    Text("Traffic Dashboard")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.purple)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)

                Toggle("Block Reels", isOn: $blockReelsEnabled)
                    .padding(.horizontal, 40)

                // Status with color coding
                HStack {
                    Circle()
                        .fill(VPNManager.statusColor(for: vpnManager.vpnStatus))
                        .frame(width: 10, height: 10)
                    Text("Status: \(vpnManager.statusString)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                // App-side status log
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Log:")
                        .font(.caption.bold())
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(vpnManager.statusLog.reversed(), id: \.self) { line in
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

                // Tunnel extension log viewer
                Button("Show Extension Log") {
                    vpnManager.refreshTunnelLog()
                    showLog = true
                }
                .font(.caption)

                Button("Refresh Extension Log") {
                    vpnManager.refreshTunnelLog()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .sheet(isPresented: $showLog) {
                NavigationView {
                    ScrollView {
                        Text(vpnManager.tunnelLog)
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
                                    UIPasteboard.general.string = vpnManager.tunnelLog
                                }
                                Button("Refresh") { vpnManager.refreshTunnelLog() }
                            }
                        }
                    }
                }
            }
            .onAppear {
                vpnManager.setup()
            }
        }
    }
}

#Preview {
    ContentView()
}
