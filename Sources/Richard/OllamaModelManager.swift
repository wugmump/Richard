import Foundation

/// Installation/availability state for the selected Ollama model.
enum OllamaModelState: Equatable {
    case unknown
    case unreachable(String)
    case missing
    case installed
    case pulling(String)
    case failed(String)

    /// Human-readable state text shown in settings.
    var label: String {
        switch self {
        case .unknown:
            "Not checked"
        case .unreachable(let message):
            "Ollama unavailable: \(message)"
        case .missing:
            "Model not installed"
        case .installed:
            "Model installed"
        case .pulling(let status):
            status
        case .failed(let message):
            "Model setup failed: \(message)"
        }
    }

    /// True while a pull/download request is in progress.
    var isBusy: Bool {
        if case .pulling = self { true } else { false }
    }
}

/// Talks to the local Ollama daemon for model setup and health checks.
@MainActor
final class OllamaModelManager: ObservableObject {
    /// Current model setup state exposed to SwiftUI.
    @Published private(set) var state: OllamaModelState = .unknown

    /// Checks whether the configured Ollama model is present locally.
    func check(settings: AppSettings) async {
        guard settings.backendKind == .ollama else {
            state = .unknown
            return
        }

        await check(backendURL: settings.backendURL, modelName: settings.modelName)
    }

    /// Checks whether an arbitrary Ollama model is present locally.
    func check(backendURL: String, modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            state = .missing
            return
        }

        do {
            let tags = try await fetchTags(backendURL: backendURL)
            state = tags.contains(trimmedModelName) ? .installed : .missing
        } catch {
            state = .unreachable(error.localizedDescription)
        }
    }

    /// Pulls the selected Ollama model, then re-checks installation state.
    func pull(settings: AppSettings) async {
        guard settings.backendKind == .ollama else { return }
        await pull(backendURL: settings.backendURL, modelName: settings.modelName)
    }

    /// Pulls an arbitrary Ollama model, then re-checks installation state.
    func pull(backendURL: String, modelName: String) async {
        state = .pulling("Starting model download...")
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            state = .failed("Model name is empty.")
            return
        }

        do {
            let status = try await pullModel(backendURL: backendURL, modelName: trimmedModelName)
            state = status == "success" ? .installed : .pulling(status)
            await check(backendURL: backendURL, modelName: trimmedModelName)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Fetches the set of installed Ollama model names and aliases.
    private func fetchTags(backendURL: String) async throws -> Set<String> {
        let rootURL = try validatedURL(backendURL)
        let endpoint = rootURL.appending(path: "api/tags")
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return Set(decoded.models.flatMap { [$0.name, $0.model] })
    }

    /// Sends a non-streaming model pull request to Ollama.
    private func pullModel(backendURL: String, modelName: String) async throws -> String {
        let rootURL = try validatedURL(backendURL)
        let endpoint = rootURL.appending(path: "api/pull")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60
        request.httpBody = try JSONEncoder().encode(OllamaPullRequest(model: modelName, stream: false))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(OllamaPullResponse.self, from: data)
        return decoded.status
    }

    /// Normalizes and validates the configured backend URL.
    private func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChatClientError.invalidURL
        }
        return url
    }

    /// Converts non-2xx HTTP responses into the same errors used by chat calls.
    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatClientError.emptyResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChatClientError.badResponse(httpResponse.statusCode)
        }
    }
}

/// Response model for Ollama's installed-model list.
private struct OllamaTagsResponse: Decodable {
    let models: [OllamaInstalledModel]
}

/// One installed model entry returned by Ollama.
private struct OllamaInstalledModel: Decodable {
    let name: String
    let model: String
}

/// Request body for `/api/pull`.
private struct OllamaPullRequest: Encodable {
    let model: String
    let stream: Bool
}

/// Non-streaming pull response.
private struct OllamaPullResponse: Decodable {
    let status: String
}
