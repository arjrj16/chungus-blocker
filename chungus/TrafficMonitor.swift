import Foundation
import Combine

@MainActor
final class TrafficMonitor: ObservableObject {
    @Published var current: TrafficSnapshot?
    @Published var history: [TrafficSnapshot] = []

    private var timer: AnyCancellable?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let statsFileURL: URL? = {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BubbleConstants.appGroupID
        )?.appendingPathComponent(BubbleConstants.statsFileName)
    }()

    func startPolling() {
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    func clearHistory() {
        history.removeAll()
        current = nil
    }

    // Cumulative bytes down from history
    var cumulativeBytesDown: Int {
        history.reduce(0) { total, snapshot in
            total + snapshot.connections.reduce(0) { $0 + $1.bytesDown }
        }
    }

    private func refresh() {
        guard let url = statsFileURL,
              let data = try? Data(contentsOf: url) else {
            return
        }

        // The tunnel writes the full history array now
        if let snapshots = try? decoder.decode([TrafficSnapshot].self, from: data), !snapshots.isEmpty {
            history = snapshots
            current = snapshots.last
        }
    }
}
