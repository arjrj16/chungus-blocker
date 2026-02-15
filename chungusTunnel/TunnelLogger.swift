import Foundation

/// Writes log lines to a shared file in the app group container so the main app can display them.
/// Both the app and extension have access to group.com.arjun.chungus.
final class TunnelLogger {

    static let shared = TunnelLogger()

    private let fileURL: URL?
    private let lock = NSLock()

    private init() {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.arjun.chungus") {
            self.fileURL = container.appendingPathComponent("tunnel_log.txt")
        } else {
            self.fileURL = nil
        }
    }

    func log(_ message: String, function: String = #function) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(function)] \(message)\n"

        // Also log to system log so Console.app can pick it up
        NSLog("[TunnelLog] %@", message)

        guard let fileURL = fileURL else { return }

        lock.lock()
        defer { lock.unlock() }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        guard let fileURL = fileURL else { return }
        try? "".data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    static func readLog() -> String {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.arjun.chungus") else {
            return "(no app group container)"
        }
        let fileURL = container.appendingPathComponent("tunnel_log.txt")
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(no logs yet)"
    }
}
