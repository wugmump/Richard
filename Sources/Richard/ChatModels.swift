import Foundation

/// A single message in Richard's visible transcript and model history.
///
/// The same value is used for native UI rendering, remote JSON responses,
/// persisted transcript storage, and prompt construction.
struct ChatMessage: Identifiable, Equatable, Codable {
    /// OpenAI/Ollama-compatible role labels.
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    /// Stable identifier for SwiftUI list diffing and scroll targeting.
    let id: UUID
    /// Message role as understood by chat-completion backends.
    let role: Role
    /// Optional human name for multi-user remote chat messages.
    var author: String?
    /// Raw message text shown in the app.
    var content: String
    /// Local image attachments associated with the visible message.
    var imagePaths: [String]?
    /// Timestamp used for transcript persistence and diagnostics.
    let createdAt: Date

    /// Creates a transcript message with default identity and timestamp.
    init(
        id: UUID = UUID(),
        role: Role,
        author: String? = nil,
        content: String,
        imagePaths: [String]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.author = author
        self.content = content
        self.imagePaths = imagePaths
        self.createdAt = createdAt
    }

    /// Content sent to the model.
    ///
    /// User names are folded into the text because many local chat APIs only
    /// support `role` + `content`, not a separate participant/name field.
    var modelContent: String {
        guard let author, !author.isEmpty else { return content }
        return "\(author) said: \(content)"
    }
}

/// Request body for Ollama's `/api/chat` endpoint.
struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let options: OllamaOptions?
}

/// Generation controls sent to Ollama.
///
/// These keep Richard responsive by limiting context and answer length rather
/// than allowing the local model to ramble for minutes.
struct OllamaOptions: Encodable {
    let numCtx: Int
    let numPredict: Int
    let temperature: Double
    let topP: Double

    enum CodingKeys: String, CodingKey {
        case numCtx = "num_ctx"
        case numPredict = "num_predict"
        case temperature
        case topP = "top_p"
    }
}

/// Backend-neutral role/content message shape used by both Ollama and
/// OpenAI-compatible APIs.
struct OllamaMessage: Codable {
    let role: String
    let content: String
    let images: [String]?

    init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

/// Response body returned by Ollama.
struct OllamaChatResponse: Decodable {
    let message: OllamaMessage?
    let response: String?
    let done: Bool?
    let error: String?
}

/// Request body for OpenAI-compatible local servers.
struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let maxTokens: Int?
    let temperature: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case maxTokens = "max_tokens"
        case temperature
    }
}

/// Minimal OpenAI-compatible response model.
struct OpenAIChatResponse: Decodable {
    /// One completion candidate from the backend.
    struct Choice: Decodable {
        let message: OllamaMessage?
    }

    /// Error shape returned by OpenAI-compatible servers.
    struct APIError: Decodable {
        let message: String
    }

    let choices: [Choice]?
    let error: APIError?
}
