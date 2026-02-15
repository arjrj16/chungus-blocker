import SwiftUI
import NetworkExtension
import Combine

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager()

    @AppStorage(BubbleConstants.blockReelsEnabledKey,
                store: UserDefaults(suiteName: BubbleConstants.appGroupID))
    private var blockReelsEnabled: Bool = true

    @StateObject private var domainThresholds = DomainThresholdsStore()

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

                if blockReelsEnabled {
                    VStack(spacing: 12) {
                        ForEach(BubbleConstants.trackedDomains, id: \.self) { domain in
                            DomainThresholdRow(
                                domain: domain,
                                threshold: domainThresholds.binding(for: domain)
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }

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

// MARK: - Domain Thresholds Store

class DomainThresholdsStore: ObservableObject {
    @Published var thresholds: [String: Int] = [:]

    private let defaults = UserDefaults(suiteName: BubbleConstants.appGroupID)

    init() { load() }

    func load() {
        guard let data = defaults?.data(forKey: BubbleConstants.domainThresholdsKey),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else {
            // Default: all domains set to no limit
            thresholds = [:]
            return
        }
        thresholds = dict
    }

    func save() {
        guard let data = try? JSONEncoder().encode(thresholds) else { return }
        defaults?.set(data, forKey: BubbleConstants.domainThresholdsKey)
    }

    func binding(for domain: String) -> Binding<Int> {
        Binding(
            get: { self.thresholds[domain] ?? BubbleConstants.noLimitThreshold },
            set: { newValue in
                self.thresholds[domain] = newValue
                self.save()
            }
        )
    }
}

// MARK: - Per-Domain Slider Row

private struct DomainThresholdRow: View {
    let domain: String
    @Binding var threshold: Int

    private let maxSliderValue: Double = 5_242_880 + 10_240 // 5 MB + one step = "No limit"

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(domain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text(thresholdLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(threshold == BubbleConstants.noLimitThreshold ? .green : (threshold == 0 ? .red : .orange))
            }
            Slider(
                value: Binding(
                    get: { threshold == BubbleConstants.noLimitThreshold ? maxSliderValue : Double(threshold) },
                    set: { newVal in
                        if newVal >= 5_242_880 + 5_120 {
                            threshold = BubbleConstants.noLimitThreshold
                        } else {
                            threshold = Int(newVal)
                        }
                    }
                ),
                in: 0...maxSliderValue,
                step: 10_240
            )
        }
    }

    private var thresholdLabel: String {
        if threshold == BubbleConstants.noLimitThreshold { return "No limit" }
        if threshold == 0 { return "BLOCK ALL" }
        if threshold < 1_048_576 {
            return String(format: "%.0f KB", Double(threshold) / 1024)
        }
        return String(format: "%.1f MB", Double(threshold) / 1_048_576)
    }
}

#Preview {
    ContentView()
}
