import Foundation

/// Supported chat backend families.
enum BackendKind: String, CaseIterable, Identifiable {
    case ollama
    case openAICompatible

    /// Stable SwiftUI identity.
    var id: String { rawValue }

    /// Label shown in settings and sidebar UI.
    var label: String {
        switch self {
        case .ollama: "Ollama"
        case .openAICompatible: "llama.cpp"
        }
    }

    /// Default local URL for each backend family.
    var defaultURL: String {
        switch self {
        case .ollama: "http://localhost:11434"
        case .openAICompatible: "http://localhost:8080"
        }
    }
}

/// Curated model configuration shown in settings.
///
/// A profile contains both the machine-readable backend values and the
/// human-readable install/selection guidance displayed in the app.
struct ModelProfile: Identifiable, Equatable {
    /// Stable app-local identifier.
    let id: String
    /// Friendly display name.
    let name: String
    /// Backend model identifier passed to Ollama or an OpenAI-compatible server.
    let modelName: String
    /// Backend family for this profile.
    let backendKind: BackendKind
    /// Base URL for the backend.
    let backendURL: String
    /// Quantization label shown to the user.
    let quantization: String
    /// Approximate disk/memory footprint guidance.
    let footprint: String
    /// Recommended context guidance.
    let context: String
    /// Short description of why this model exists in the list.
    let summary: String
    /// Command the user can run to install or start the model.
    let installCommand: String
    /// Source page for model details.
    let sourceURL: URL

    /// Higher-quality default model profile.
    static let recommended = ModelProfile(
        id: "cydonia-24b-v4-3-q4",
        name: "Cydonia 24B v4.3 Q4",
        modelName: "hf.co/TheDrummer/Cydonia-24B-v4.3-GGUF:Q4_K_M",
        backendKind: .ollama,
        backendURL: BackendKind.ollama.defaultURL,
        quantization: "Q4_K_M",
        footprint: "14.3 GB model file",
        context: "Use 8K to start; increase if memory pressure stays low.",
        summary: "Best default for this Mac: stronger roleplay and conversation quality than 8B models while still fitting 36 GB unified memory.",
        installCommand: "ollama run hf.co/TheDrummer/Cydonia-24B-v4.3-GGUF:Q4_K_M",
        sourceURL: URL(string: "https://huggingface.co/TheDrummer/Cydonia-24B-v4.3-GGUF")!
    )

    /// Faster fallback model profile for lower-latency interaction.
    static let fastFallback = ModelProfile(
        id: "stheno-8b-v3-2",
        name: "Stheno 8B v3.2",
        modelName: "hf.co/QuantFactory/L3-8B-Stheno-v3.2-GGUF:Q4_K_M",
        backendKind: .ollama,
        backendURL: BackendKind.ollama.defaultURL,
        quantization: "Q4_K_M",
        footprint: "Smaller 8B class model",
        context: "Good for faster iteration and lower memory use.",
        summary: "Fallback for speed: built for one-on-one roleplay with better instruction adherence than earlier Stheno versions.",
        installCommand: "ollama run hf.co/QuantFactory/L3-8B-Stheno-v3.2-GGUF:Q4_K_M",
        sourceURL: URL(string: "https://huggingface.co/Sao10K/L3-8B-Stheno-v3.2")!
    )

    /// Profiles shown in the settings picker.
    static let all: [ModelProfile] = [.recommended, .fastFallback]
}
