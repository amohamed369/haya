import Foundation

/// In-memory circular log buffer for displaying logs in the Activity tab.
/// Dual-writes alongside os.Logger so logs are visible both in Xcode console and in-app.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published var entries: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: String
        let message: String
    }

    enum Level: String, CaseIterable {
        case debug, info, warning, error

        var symbol: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    func log(_ level: Level, _ category: String, _ message: String) {
        let entry = LogEntry(timestamp: .now, level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func formatted() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { e in
            "[\(formatter.string(from: e.timestamp))] [\(e.level.rawValue.uppercased())] [\(e.category)] \(e.message)"
        }.joined(separator: "\n")
    }
}
