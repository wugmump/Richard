import Foundation

/// Persists the visible chat transcript in `UserDefaults`.
///
/// The store is deliberately separate from the prompt compaction logic. The UI
/// can keep a longer visible history while the model receives a much smaller
/// context window from `ChatViewModel`.
@MainActor
final class ChatTranscriptStore {
    /// `UserDefaults` key for the encoded `[ChatMessage]`.
    private let storageKey = "richard.chatTranscript"
    /// Hard cap to prevent the persisted transcript from growing without bound.
    private let maxStoredMessages = 400
    /// Per-message cap for persisted visible text. Prompt preparation has its
    /// own smaller compaction path, so visible messages can retain longer output.
    private let maxStoredContentCharacters = 20_000

    /// Loads the persisted transcript, returning `nil` when there is no usable
    /// stored conversation so the caller can provide a default opener.
    func load() -> [ChatMessage]? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !messages.isEmpty else {
            return nil
        }
        let sanitized = sanitize(messages)
        if sanitized != messages {
            save(sanitized)
        }
        return sanitized
    }

    /// Saves only the newest messages. Older messages may still be represented
    /// in Richard's separate user-feeling store and compacted context.
    func save(_ messages: [ChatMessage]) {
        let storedMessages = sanitize(Array(messages.suffix(maxStoredMessages)))
        guard let data = try? JSONEncoder().encode(storedMessages) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Removes the visible transcript from persisted storage.
    func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Truncates oversized message bodies while preserving identity, role, and
    /// timestamp metadata.
    private func sanitize(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            guard message.content.count > maxStoredContentCharacters else {
                return message
            }

            var trimmed = message
            let endIndex = trimmed.content.index(trimmed.content.startIndex, offsetBy: maxStoredContentCharacters)
            trimmed.content = String(trimmed.content[..<endIndex]) + "\n[message truncated for performance]"
            return trimmed
        }
    }
}
