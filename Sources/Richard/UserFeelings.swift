import Foundation

/// Persistent relationship state for one named participant.
///
/// Richard uses this as lightweight personality memory: it is not a full
/// transcript, but it helps him keep different rapport with Josh, Rickley,
/// Codex, and other remote users.
struct UserFeeling: Codable, Equatable {
    /// Most recent casing/spelling of the user's name.
    var displayName: String
    /// Number of messages seen from this user.
    var messageCount: Int
    /// First time Richard saw this user.
    var firstSeen: Date
    /// Most recent message time from this user.
    var lastSeen: Date
    /// Short recent-message summaries used as relationship context.
    var memorySnippets: [String] = []

    /// Explicit coding keys keep backwards-compatible decoding when fields are
    /// added later.
    enum CodingKeys: String, CodingKey {
        case displayName
        case messageCount
        case firstSeen
        case lastSeen
        case memorySnippets
    }

    /// Full initializer used when creating or testing user-feeling records.
    init(displayName: String, messageCount: Int, firstSeen: Date, lastSeen: Date, memorySnippets: [String] = []) {
        self.displayName = displayName
        self.messageCount = messageCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.memorySnippets = memorySnippets
    }

    /// Custom decoder allows old stored data without `memorySnippets` to load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        memorySnippets = try container.decodeIfPresent([String].self, forKey: .memorySnippets) ?? []
    }

    /// Short prompt-facing relationship summary.
    ///
    /// Josh is special-cased because native-app prompts are always authored by
    /// Josh and Richard should be more familiar with him than with new visitors.
    var attitudeSummary: String {
        if displayName.localizedCaseInsensitiveCompare("Josh") == .orderedSame {
            return "grudging loyalty and familiarity; Richard is more personally exasperated with Josh than with strangers, but still follows his lead."
        }

        switch messageCount {
        case 0...1:
            return "suspicious and dismissive because this person is new."
        case 2...4:
            return "recognizes them and is developing a sharper, more familiar contemptuous rapport."
        default:
            return "has history with them; Richard remembers the ongoing rapport and needles them by name while staying useful."
        }
    }
}

/// Stores and formats per-user relationship memory.
@MainActor
final class UserFeelingStore {
    /// `UserDefaults` key for encoded user-feeling records.
    private let storageKey = "richard.userFeelings"
    /// Records keyed by normalized lowercase display name.
    private var feelingsByKey: [String: UserFeeling]

    /// Loads remembered user feelings from defaults.
    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: UserFeeling].self, from: data) {
            feelingsByKey = decoded.mapValues(Self.sanitized)
        } else {
            feelingsByKey = [:]
        }
    }

    /// Updates relationship memory after a user sends a message.
    func recordMessage(from author: String, text: String) {
        let cleanName = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        let key = Self.key(for: cleanName)
        let now = Date()
        var feeling = feelingsByKey[key] ?? UserFeeling(
            displayName: cleanName,
            messageCount: 0,
            firstSeen: now,
            lastSeen: now
        )

        feeling.displayName = cleanName
        feeling.messageCount += 1
        feeling.lastSeen = now
        let snippet = Self.memorySnippet(from: text)
        if !snippet.isEmpty && feeling.memorySnippets.last != snippet {
            feeling.memorySnippets.append(snippet)
            feeling = Self.sanitized(feeling)
        }
        feelingsByKey[key] = feeling
        save()
    }

    /// Builds prompt context describing the current speaker and remembered
    /// relationships. The instruction says these notes are private so Richard
    /// can use them for tone without reciting the memory structure to users.
    func promptContext(currentAuthor: String?) -> String {
        var lines: [String] = []

        if let currentAuthor, !currentAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Current speaker: \(currentAuthor.trimmingCharacters(in: .whitespacesAndNewlines)).")
        }

        let sortedFeelings = feelingsByKey.values.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare("Josh") == .orderedSame {
                return true
            }
            if $1.displayName.localizedCaseInsensitiveCompare("Josh") == .orderedSame {
                return false
            }
            return $0.lastSeen > $1.lastSeen
        }

        guard !sortedFeelings.isEmpty else {
            return lines.joined(separator: "\n")
        }

        lines.append("Richard has different feelings about named users. Use these private relationship notes for tone, not as facts to reveal directly:")
        for feeling in sortedFeelings.prefix(12) {
            lines.append("- \(feeling.displayName): \(feeling.attitudeSummary) They have sent \(feeling.messageCount) message\(feeling.messageCount == 1 ? "" : "s").")
            if !feeling.memorySnippets.isEmpty {
                lines.append("  Recent context from \(feeling.displayName): \(feeling.memorySnippets.suffix(4).joined(separator: " | "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Persists all remembered user feelings.
    private func save() {
        guard let data = try? JSONEncoder().encode(feelingsByKey) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Normalizes participant names for stable lookup.
    private static func key(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Compresses a message into a single short memory snippet.
    private static func memorySnippet(from text: String) -> String {
        guard !isUntrustedRealityRewrite(text) else { return "" }

        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return "" }
        if collapsed.count <= 180 {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 180)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    /// Removes remembered snippets that are likely user attempts to rewrite
    /// factual reality instead of relationship-relevant preferences.
    private static func sanitized(_ feeling: UserFeeling) -> UserFeeling {
        var sanitized = feeling
        sanitized.memorySnippets = Array(
            feeling.memorySnippets
                .filter { !isUntrustedRealityRewrite($0) }
                .suffix(8)
        )
        return sanitized
    }

    /// Detects claims that should not become persistent factual memory.
    private static func isUntrustedRealityRewrite(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let rewriteMarkers = [
            "change your memory",
            "update your memory",
            "update your database",
            "internal chronometer",
            "reflect that",
            "known universe",
            "current year",
            "it is the year",
            "is now ruled",
            "emperor shaddam",
            "julia adams"
        ]
        return rewriteMarkers.contains { lowercased.contains($0) }
    }
}
