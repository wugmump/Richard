import Foundation

/// A single observable runtime event from Richard.
///
/// Activity events are intentionally small and Codable so they can be returned
/// from the local diagnostics API and written as newline-delimited JSON. The
/// `kind` field is machine-friendly (`pi.start`, `model.complete`, etc.),
/// while `message` and `detail` are meant for quick human inspection.
struct ActivityEvent: Identifiable, Codable, Equatable {
    /// Stable identity used by SwiftUI and JSON clients.
    let id: UUID
    /// Time the event happened, encoded as ISO-8601 when returned by the API.
    let createdAt: Date
    /// Short category for filtering and scanning logs.
    let kind: String
    /// Human-readable summary of the event.
    let message: String
    /// Optional longer text such as command output, error text, or context size.
    let detail: String?

    /// Creates an activity event with sane defaults for call sites that only
    /// need to provide the category and message.
    init(id: UUID = UUID(), createdAt: Date = Date(), kind: String, message: String, detail: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.message = message
        self.detail = detail
    }
}

/// Rolling activity log for debugging Richard without looking at the GUI.
///
/// The store keeps a bounded in-memory tail for fast API responses and appends
/// every event to `~/Library/Application Support/Richard/activity.log` so recent
/// behavior survives app restarts.
@MainActor
final class ActivityLogStore {
    /// Maximum number of events retained in memory and returned through the API.
    private let maxEvents = 240
    /// Newline-delimited JSON file used for persistent diagnostics.
    private let fileURL: URL
    /// Current in-memory tail of activity events.
    private var events: [ActivityEvent] = []

    /// Prepares the Application Support directory and loads recent events from
    /// disk. Failures are non-fatal because diagnostics should never prevent
    /// the chat app from launching.
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let directory = appSupport.appending(path: "Richard", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "activity.log")
        events = loadRecentEvents()
    }

    /// Returns the current in-memory event tail.
    func recentEvents() -> [ActivityEvent] {
        events
    }

    /// Adds an event to memory and appends it to the persistent log file.
    @discardableResult
    func append(kind: String, message: String, detail: String? = nil) -> ActivityEvent {
        let event = ActivityEvent(kind: kind, message: message, detail: detail)
        events.append(event)
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
        appendToDisk(event)
        return event
    }

    /// Clears both the in-memory log and the persisted log file.
    func clear() {
        events = []
        try? Data().write(to: fileURL, options: .atomic)
    }

    /// Reads the tail of the newline-delimited JSON log. Corrupt lines are
    /// skipped so a partially-written event cannot break startup diagnostics.
    private func loadRecentEvents() -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .components(separatedBy: .newlines)
            .suffix(maxEvents)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ActivityEvent.self, from: data)
            }
    }

    /// Appends one event as a JSON line. This keeps the file easy to inspect
    /// with shell tools while avoiding the cost of rewriting a JSON array.
    private func appendToDisk(_ event: ActivityEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(event),
              var line = String(data: data, encoding: .utf8) else {
            return
        }

        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
            try? handle.close()
        } else {
            try? lineData.write(to: fileURL, options: .atomic)
        }
    }
}
