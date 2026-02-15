import SwiftUI
import Charts

struct TrafficDashboardView: View {
    @StateObject private var monitor = TrafficMonitor()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Section 1: Stats counters (tappable)
                StatsCountersView(stats: monitor.current?.stats, events: monitor.events)

                // Section 2: Top 5 Domains
                TopDomainsChartView(domains: Array((monitor.current?.topDomains ?? []).prefix(5)))

                // Section 3: Cumulative bytes timeline
                BytesTimelineView(history: monitor.history)

                // Section 4: Instant bytes timeline
                InstantBytesView(history: monitor.history)

                // Section 5: Active connections
                ActiveConnectionsView(
                    connections: monitor.current?.connections ?? []
                )
            }
            .padding()
        }
        .navigationTitle("Traffic Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { monitor.startPolling() }
        .onDisappear { monitor.stopPolling() }
    }
}

// MARK: - Stats Counters

private struct StatsCountersView: View {
    let stats: StatsSnapshot?
    let events: [TrafficEvent]

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                EventListView(title: "All Events", events: events, color: .primary)
            } label: {
                StatBox(label: "Total", value: stats?.totalConns ?? 0, color: .primary)
            }
            .buttonStyle(.plain)

            NavigationLink {
                EventListView(title: "Allowed", events: events.filter { $0.type == .allowed || $0.type == .completed }, color: .green)
            } label: {
                StatBox(label: "Allowed", value: stats?.tcpAllowed ?? 0, color: .green)
            }
            .buttonStyle(.plain)

            NavigationLink {
                EventListView(title: "Blocked", events: events.filter { $0.type == .blocked || $0.type == .streamBlocked }, color: .red)
            } label: {
                StatBox(label: "Blocked", value: stats?.tcpBlocked ?? 0, color: .red)
            }
            .buttonStyle(.plain)

            NavigationLink {
                EventListView(title: "Errors", events: events.filter { $0.type == .error }, color: .orange)
            } label: {
                StatBox(label: "Errors", value: stats?.errors ?? 0, color: .orange)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatBox: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

// MARK: - Event List

struct EventListView: View {
    let title: String
    let events: [TrafficEvent]
    let color: Color

    var body: some View {
        List {
            ForEach(events.reversed()) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        EventTypeBadge(type: event.type)
                        Spacer()
                        Text(event.timestamp, style: .time)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Text(event.sni ?? event.host)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)

                    if event.host != event.sni ?? "" {
                        Text("\(event.host):\(event.port)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Text(event.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    if let bytes = event.bytesDown, bytes > 0 {
                        Text(formatBytes(bytes) + " down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EventTypeBadge: View {
    let type: EventType

    private var label: String {
        switch type {
        case .allowed: return "ALLOWED"
        case .blocked: return "BLOCKED"
        case .streamBlocked: return "STREAM BLOCKED"
        case .error: return "ERROR"
        case .completed: return "COMPLETED"
        }
    }

    private var badgeColor: Color {
        switch type {
        case .allowed: return .green
        case .blocked: return .red
        case .streamBlocked: return .red
        case .error: return .orange
        case .completed: return .blue
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor)
            .cornerRadius(4)
    }
}

// MARK: - Top Domains Chart

private struct TopDomainsChartView: View {
    let domains: [DomainSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Domains")
                .font(.headline)

            if domains.isEmpty {
                Text("No data yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            } else {
                Chart(domains) { domain in
                    BarMark(
                        x: .value("Bytes", domain.totalBytes),
                        y: .value("Domain", shortDomain(domain.domain))
                    )
                    .foregroundStyle(.orange)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("\(domain.count)x")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let bytes = value.as(Int.self) {
                                Text(formatBytes(bytes))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: CGFloat(max(domains.count, 1) * 36 + 30))
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func shortDomain(_ domain: String) -> String {
        // Shorten "scontent-sjc6-1.cdninstagram.com" → "scontent-sjc6-1.cdn..."
        if domain.count > 25 {
            return String(domain.prefix(22)) + "..."
        }
        return domain
    }
}

// MARK: - Bytes Timeline

private struct BytesTimelineView: View {
    let history: [TrafficSnapshot]

    private var dataPoints: [(Date, Int)] {
        var cumulative = 0
        return history.map { snapshot in
            let snapshotBytes = snapshot.connections.reduce(0) { $0 + $1.bytesDown }
            cumulative += snapshotBytes
            return (snapshot.timestamp, cumulative)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cumulative Bytes Down")
                .font(.headline)

            if history.isEmpty {
                Text("No data yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(Array(dataPoints.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.0),
                            y: .value("Bytes", point.1)
                        )
                        .foregroundStyle(.blue)

                        AreaMark(
                            x: .value("Time", point.0),
                            y: .value("Bytes", point.1)
                        )
                        .foregroundStyle(.blue.opacity(0.1))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let bytes = value.as(Int.self) {
                                Text(formatBytes(bytes))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Instant Bytes

private struct InstantBytesView: View {
    let history: [TrafficSnapshot]

    private var dataPoints: [(Date, Int)] {
        guard history.count > 1 else { return [] }
        var points: [(Date, Int)] = []
        for i in 1..<history.count {
            let prev = history[i - 1]
            let curr = history[i]

            // Skip gaps > 2s (e.g. app was backgrounded)
            if curr.timestamp.timeIntervalSince(prev.timestamp) > 2.0 { continue }

            // Per-connection delta so appearing/disappearing connections don't skew
            let prevLookup = Dictionary(uniqueKeysWithValues: prev.connections.map { ($0.id, $0.bytesDown) })
            var delta = 0
            for conn in curr.connections {
                delta += max(conn.bytesDown - (prevLookup[conn.id] ?? 0), 0)
            }
            points.append((curr.timestamp, delta))
        }
        return points
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bytes Down (per snapshot)")
                .font(.headline)

            if history.isEmpty {
                Text("No data yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(Array(dataPoints.enumerated()), id: \.offset) { _, point in
                        BarMark(
                            x: .value("Time", point.0),
                            y: .value("Bytes", point.1)
                        )
                        .foregroundStyle(.green)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let bytes = value.as(Int.self) {
                                Text(formatBytes(bytes))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Active Connections

private struct ActiveConnectionsView: View {
    let connections: [ConnectionSnapshot]

    private var activeConns: [ConnectionSnapshot] {
        connections.filter(\.isActive)
    }

    private var recentlyClosedConns: [ConnectionSnapshot] {
        connections.filter { !$0.isActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Connections (\(activeConns.count))")
                .font(.headline)

            if activeConns.isEmpty && recentlyClosedConns.isEmpty {
                Text("No connections")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(activeConns) { conn in
                ConnectionRow(connection: conn)
            }

            if !recentlyClosedConns.isEmpty {
                Text("Recently Closed")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                ForEach(recentlyClosedConns) { conn in
                    ConnectionRow(connection: conn)
                        .opacity(0.5)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

private struct ConnectionRow: View {
    let connection: ConnectionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.sni ?? connection.host)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1)
                    Text("#\(connection.id) · \(connection.host):\(connection.port)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBytes(connection.totalBytes))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(durationString(from: connection.startTime))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Bytes bar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    let total = max(connection.totalBytes, 1)
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: geo.size.width * CGFloat(connection.bytesUp) / CGFloat(total))
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: geo.size.width * CGFloat(connection.bytesDown) / CGFloat(total))
                }
            }
            .frame(height: 4)
            .cornerRadius(2)

            HStack {
                Label(formatBytes(connection.bytesUp), systemImage: "arrow.up")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Spacer()
                Label(formatBytes(connection.bytesDown), systemImage: "arrow.down")
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
            }
        }
        .padding(10)
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(connection.isActive ? Color.green.opacity(0.4) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func durationString(from start: Date) -> String {
        let secs = Date().timeIntervalSince(start)
        if secs < 60 { return String(format: "%.0fs", secs) }
        return String(format: "%.0fm %.0fs", secs / 60, secs.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Shared Helpers

private func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024
    return String(format: "%.1f MB", mb)
}
