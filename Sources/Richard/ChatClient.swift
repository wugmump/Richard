import AppKit
import ImageIO
import Foundation
import UniformTypeIdentifiers

/// Errors surfaced by local or OpenAI-compatible chat backends.
enum ChatClientError: LocalizedError {
    case invalidURL
    case badResponse(Int)
    case backend(String)
    case emptyResponse
    case timeout(TimeInterval)

    /// User-facing error message shown in the chat UI and remote API.
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The backend URL is invalid."
        case .badResponse(let status):
            "The model backend returned HTTP \(status)."
        case .backend(let message):
            message
        case .emptyResponse:
            "The model backend returned an empty response."
        case .timeout(let seconds):
            "The model backend did not respond within \(Int(seconds)) seconds."
        }
    }
}

/// Thin client for non-streaming chat completion calls.
///
/// The app currently supports Ollama and OpenAI-compatible local servers. The
/// view model owns prompt construction and tool loops; this type only converts
/// `[ChatMessage]` into backend HTTP requests and parses the reply.
struct ChatClient {
    /// Backend root URL, for example `http://localhost:11434`.
    var backendURL: String
    /// Backend protocol family.
    var backendKind: BackendKind
    /// Model identifier understood by the backend.
    var modelName: String

    /// Sends a complete chat prompt and returns the assistant text.
    func send(messages: [ChatMessage], systemPrompt: String) async throws -> String {
        guard let rootURL = URL(string: backendURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChatClientError.invalidURL
        }

        let endpoint = rootURL.appending(path: backendKind == .ollama ? "api/chat" : "v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // The system prompt is sent as a normal first message so the same shape
        // works across Ollama and OpenAI-compatible endpoints.
        let ollamaMessages = [OllamaMessage(role: "system", content: systemPrompt)]
            + messages.map { OllamaMessage(role: $0.role.rawValue, content: $0.modelContent) }

        switch backendKind {
        case .ollama:
            request.httpBody = try JSONEncoder().encode(
                OllamaChatRequest(
                        model: modelName,
                        messages: ollamaMessages,
                        stream: false,
                        // Keep the model responsive while leaving enough room
                        // to finish longer answers cleanly.
                        options: OllamaOptions(
                        numCtx: 4096,
                        numPredict: 900,
                        temperature: 0.75,
                        topP: 0.9
                    )
                )
            )
        case .openAICompatible:
            request.httpBody = try JSONEncoder().encode(
                OpenAIChatRequest(
                    model: modelName,
                    messages: ollamaMessages,
                    stream: false,
                    maxTokens: 900,
                    temperature: 0.75
                )
            )
        }

        // `URLSession`'s timeout is not always enough to unwind a wedged local
        // model call, so wrap it in an explicit task-group timeout as well.
        let preparedRequest = request
        let (data, response) = try await withTimeout(seconds: preparedRequest.timeoutInterval) {
            try await URLSession.shared.data(for: preparedRequest)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatClientError.emptyResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChatClientError.badResponse(httpResponse.statusCode)
        }

        // Ollama and OpenAI-compatible servers use different response envelopes.
        switch backendKind {
        case .ollama:
            let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            if let error = decoded.error, !error.isEmpty {
                throw ChatClientError.backend(error)
            }

            if let message = decoded.message?.content, !message.isEmpty {
                return message
            }

            if let response = decoded.response, !response.isEmpty {
                return response
            }
        case .openAICompatible:
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            if let error = decoded.error {
                throw ChatClientError.backend(error.message)
            }

            if let message = decoded.choices?.first?.message?.content, !message.isEmpty {
                return message
            }
        }

        throw ChatClientError.emptyResponse
    }

    /// Sends one local image to an Ollama vision model and returns a concise
    /// text description that the main chat model can reason over.
    func analyzeImage(imagePath: String, prompt: String, visionModelName: String) async throws -> String {
        guard backendKind == .ollama else {
            throw ChatClientError.backend("Image analysis currently requires Ollama.")
        }

        guard let rootURL = URL(string: backendURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChatClientError.invalidURL
        }

        let expandedPath = Self.expandedPath(imagePath)
        let imageURL = URL(fileURLWithPath: expandedPath)
        let imageData = try Self.normalizedVisionImageData(from: imageURL)
        let imageBase64 = imageData.base64EncodedString()
        let endpoint = rootURL.appending(path: "api/chat")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(
                model: visionModelName,
                messages: [
                    OllamaMessage(
                        role: "system",
                        content: "You are a precise image inspection model. Describe only visible pixels. First classify the image as photo, drawing, screenshot, UI, document, or other. Do not invent operating systems, desktop environments, menus, logos, hidden text, intent, or causes."
                    ),
                    OllamaMessage(
                        role: "user",
                        content: """
                        \(prompt)

                        If the image is not actually a UI screenshot, do not describe UI state. Mention readable text only when you can see it.
                        """,
                        images: [imageBase64]
                    )
                ],
                stream: false,
                options: OllamaOptions(
                    numCtx: 2048,
                    numPredict: 220,
                    temperature: 0.2,
                    topP: 0.9
                )
            )
        )

        let preparedRequest = request
        let (data, response) = try await withTimeout(seconds: preparedRequest.timeoutInterval) {
            try await URLSession.shared.data(for: preparedRequest)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatClientError.emptyResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChatClientError.badResponse(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        if let error = decoded.error, !error.isEmpty {
            throw ChatClientError.backend(error)
        }

        if let message = decoded.message?.content, !message.isEmpty {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let response = decoded.response, !response.isEmpty {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw ChatClientError.emptyResponse
    }

    /// Converts pasted images into a vision-model-friendly RGB JPEG.
    ///
    /// Some local multimodal models hallucinate badly on tall RGBA screenshots
    /// or clipboard PNGs. Flattening alpha and capping the longest edge keeps
    /// the payload smaller and gave materially better reads in local testing.
    private static func normalizedVisionImageData(from url: URL) throws -> Data {
        let originalData = try Data(contentsOf: url)
        guard let image = NSImage(data: originalData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return originalData
        }

        let maxDimension = 1280
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        let scale = min(1.0, Double(maxDimension) / Double(max(sourceWidth, sourceHeight)))
        let targetWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return originalData
        }

        context.interpolationQuality = .high
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let normalizedImage = context.makeImage() else { return originalData }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return originalData
        }

        CGImageDestinationAddImage(
            destination,
            normalizedImage,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else { return originalData }
        return data as Data
    }

    /// Races an async operation against a sleep-based timeout.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ChatClientError.timeout(seconds)
            }

            guard let result = try await group.next() else {
                throw ChatClientError.emptyResponse
            }

            group.cancelAll()
            return result
        }
    }

    /// Expands a leading `~` in paths supplied by users or tool output.
    private static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        return NSString(string: trimmed).expandingTildeInPath
    }
}
