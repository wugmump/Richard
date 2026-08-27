import Foundation

/// One startup dependency check shown in the headless host panel.
struct RuntimeSetupCheck: Identifiable, Equatable {
    /// Stable display identity.
    let id: String
    /// Human-readable dependency name.
    let title: String
    /// Current state detail.
    let detail: String
    /// True when this check is ready enough for normal operation.
    let isReady: Bool
    /// True when the check is useful but not required for core web chat.
    let isOptional: Bool
}

/// Creates portable setup helper scripts and verifies local runtime files.
///
/// The app bundle intentionally does not include Ollama or model weights, so
/// startup needs to make external requirements visible. This manager writes
/// user-runnable setup scripts into Application Support on every launch and
/// refreshes the dependency checklist when the host panel appears.
@MainActor
final class RuntimeSetupManager: ObservableObject {
    /// Latest dependency checklist for the host panel.
    @Published private(set) var checks: [RuntimeSetupCheck] = []
    /// Directory containing generated setup scripts.
    @Published private(set) var setupDirectory: URL?
    /// Full path to the install/setup script.
    @Published private(set) var setupScriptURL: URL?
    /// Full path to the verification script.
    @Published private(set) var checkScriptURL: URL?
    /// True while startup verification is running.
    @Published private(set) var isChecking = false

    /// True when all required checks pass. Optional features may still be absent.
    var requiredReady: Bool {
        checks.allSatisfy { $0.isReady || $0.isOptional }
    }

    /// Generates scripts and checks dependencies for the current settings.
    func prepareAndCheck(settings: AppSettings) async {
        isChecking = true
        defer { isChecking = false }

        do {
            let directory = try Self.ensureSetupDirectory()
            setupDirectory = directory
            setupScriptURL = try writeSetupScript(in: directory, settings: settings)
            checkScriptURL = try writeCheckScript(in: directory, settings: settings)
            try Self.ensureRuntimeDirectories()
        } catch {
            checks = [
                RuntimeSetupCheck(
                    id: "setup-scripts",
                    title: "Setup Scripts",
                    detail: "Could not create setup files: \(error.localizedDescription)",
                    isReady: false,
                    isOptional: false
                )
            ]
            return
        }

        checks = await Self.buildChecks(settings: settings, setupScriptURL: setupScriptURL, checkScriptURL: checkScriptURL)
    }

    /// Returns the per-user setup directory and creates it if needed.
    private static func ensureSetupDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let directory = appSupport.appending(path: "Richard/Setup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Creates runtime folders that later image uploads, screenshots, and Codex
    /// bridge work rely on.
    private static func ensureRuntimeDirectories() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        for child in ["Richard/Attachments", "Richard/Screenshots", "Richard/CodexBridge"] {
            try FileManager.default.createDirectory(
                at: appSupport.appending(path: child, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    /// Writes the one-command setup script used on a freshly cloned Mac.
    private func writeSetupScript(in directory: URL, settings: AppSettings) throws -> URL {
        let url = directory.appending(path: "setup-richard.command")
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        echo "Richard setup"
        echo "============="

        if ! command -v brew >/dev/null 2>&1; then
          echo "Homebrew is missing. Install it from: https://docs.brew.sh/Installation"
          exit 1
        fi

        if ! command -v ollama >/dev/null 2>&1; then
          echo "Installing Ollama with Homebrew..."
          brew install ollama
        fi

        if ! pgrep -x ollama >/dev/null 2>&1; then
          echo "Starting Ollama..."
          nohup ollama serve > "$HOME/Library/Application Support/Richard/ollama.log" 2>&1 &
          sleep 3
        fi

        echo "Pulling chat model: \(shellQuoted(settings.modelName))"
        ollama pull \(shellQuoted(settings.modelName))

        echo "Pulling vision model: \(shellQuoted(settings.visionModelName))"
        ollama pull \(shellQuoted(settings.visionModelName))

        mkdir -p "$HOME/Library/Application Support/Richard/Attachments"
        mkdir -p "$HOME/Library/Application Support/Richard/Screenshots"
        mkdir -p "$HOME/Library/Application Support/Richard/CodexBridge"

        echo
        echo "Done. Launch Richard and use this URL when the host panel reports it:"
        echo "\(settings.shareURL)"
        """
        try writeExecutable(script, to: url)
        return url
    }

    /// Writes a non-mutating check script matching the app's startup checks.
    private func writeCheckScript(in directory: URL, settings: AppSettings) throws -> URL {
        let url = directory.appending(path: "check-richard.command")
        let script = """
        #!/usr/bin/env bash
        set -u

        echo "Richard runtime check"
        echo "====================="

        check_path() {
          if [ -e "$1" ]; then
            echo "OK      $2: $1"
          else
            echo "MISSING $2: $1"
          fi
        }

        if command -v brew >/dev/null 2>&1; then
          echo "OK      Homebrew: $(command -v brew)"
        else
          echo "MISSING Homebrew"
        fi

        if command -v ollama >/dev/null 2>&1; then
          echo "OK      Ollama: $(command -v ollama)"
        else
          echo "MISSING Ollama"
        fi

        curl -fsS "\(settings.backendURL.trimmingCharacters(in: .whitespacesAndNewlines))/api/tags" >/tmp/richard-ollama-tags.json 2>/dev/null
        if [ $? -eq 0 ]; then
          echo "OK      Model backend: \(settings.backendURL)"
          grep -Fq "\(settings.modelName)" /tmp/richard-ollama-tags.json && echo "OK      Chat model: \(settings.modelName)" || echo "MISSING Chat model: \(settings.modelName)"
          grep -Fq "\(settings.visionModelName)" /tmp/richard-ollama-tags.json && echo "OK      Vision model: \(settings.visionModelName)" || echo "OPTIONAL Vision model missing: \(settings.visionModelName)"
        else
          echo "MISSING Model backend: \(settings.backendURL)"
        fi

        check_path "$HOME/Library/Application Support/Richard/Attachments" "Attachments directory"
        check_path "$HOME/Library/Application Support/Richard/Screenshots" "Screenshots directory"
        check_path "$HOME/Library/Application Support/Richard/CodexBridge" "Codex bridge directory"
        check_path "\(settings.codexBinaryPath)" "Codex CLI"
        """
        try writeExecutable(script, to: url)
        return url
    }

    /// Writes script text and marks it executable for Finder double-clicks.
    private func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Builds current dependency checks without modifying the machine.
    private static func buildChecks(
        settings: AppSettings,
        setupScriptURL: URL?,
        checkScriptURL: URL?
    ) async -> [RuntimeSetupCheck] {
        var checks: [RuntimeSetupCheck] = []
        checks.append(pathCheck(id: "setup-script", title: "Setup Script", url: setupScriptURL, optional: false))
        checks.append(pathCheck(id: "check-script", title: "Check Script", url: checkScriptURL, optional: false))
        checks.append(commandCheck(id: "homebrew", title: "Homebrew", command: "brew", optional: false))
        checks.append(commandCheck(id: "ollama", title: "Ollama CLI", command: "ollama", optional: false))
        checks.append(pathCheck(id: "codex", title: "Codex CLI", url: URL(filePath: settings.codexBinaryPath), optional: true))

        for directory in runtimeDirectoryChecks() {
            checks.append(directory)
        }

        checks.append(contentsOf: await ollamaChecks(settings: settings))
        return checks
    }

    /// Verifies a required or optional filesystem path.
    private static func pathCheck(id: String, title: String, url: URL?, optional: Bool) -> RuntimeSetupCheck {
        guard let url else {
            return RuntimeSetupCheck(id: id, title: title, detail: "No path configured.", isReady: false, isOptional: optional)
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        return RuntimeSetupCheck(
            id: id,
            title: title,
            detail: exists ? url.path : "Missing: \(url.path)",
            isReady: exists,
            isOptional: optional
        )
    }

    /// Verifies a command is available somewhere on PATH.
    private static func commandCheck(id: String, title: String, command: String, optional: Bool) -> RuntimeSetupCheck {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["which", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ready = process.terminationStatus == 0 && output?.isEmpty == false
            return RuntimeSetupCheck(
                id: id,
                title: title,
                detail: ready ? output! : "\(command) is not on PATH.",
                isReady: ready,
                isOptional: optional
            )
        } catch {
            return RuntimeSetupCheck(id: id, title: title, detail: error.localizedDescription, isReady: false, isOptional: optional)
        }
    }

    /// Checks runtime directories created by the app.
    private static func runtimeDirectoryChecks() -> [RuntimeSetupCheck] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return [
            pathCheck(id: "attachments-dir", title: "Attachments Directory", url: appSupport.appending(path: "Richard/Attachments"), optional: false),
            pathCheck(id: "screenshots-dir", title: "Screenshots Directory", url: appSupport.appending(path: "Richard/Screenshots"), optional: false),
            pathCheck(id: "codex-bridge-dir", title: "Codex Bridge Directory", url: appSupport.appending(path: "Richard/CodexBridge"), optional: false)
        ]
    }

    /// Checks whether Ollama is reachable and whether configured models exist.
    private static func ollamaChecks(settings: AppSettings) async -> [RuntimeSetupCheck] {
        guard settings.backendKind == .ollama else {
            return [
                RuntimeSetupCheck(
                    id: "backend",
                    title: "Model Backend",
                    detail: "Using \(settings.backendKind.label); Ollama model checks skipped.",
                    isReady: true,
                    isOptional: false
                )
            ]
        }

        do {
            let tags = try await fetchOllamaTags(backendURL: settings.backendURL)
            return [
                RuntimeSetupCheck(id: "backend", title: "Ollama Server", detail: settings.backendURL, isReady: true, isOptional: false),
                RuntimeSetupCheck(
                    id: "chat-model",
                    title: "Chat Model",
                    detail: tags.contains(settings.modelName) ? settings.modelName : "Missing: \(settings.modelName)",
                    isReady: tags.contains(settings.modelName),
                    isOptional: false
                ),
                RuntimeSetupCheck(
                    id: "vision-model",
                    title: "Vision Model",
                    detail: tags.contains(settings.visionModelName) ? settings.visionModelName : "Missing: \(settings.visionModelName)",
                    isReady: tags.contains(settings.visionModelName),
                    isOptional: true
                )
            ]
        } catch {
            return [
                RuntimeSetupCheck(
                    id: "backend",
                    title: "Ollama Server",
                    detail: "Unavailable: \(error.localizedDescription)",
                    isReady: false,
                    isOptional: false
                )
            ]
        }
    }

    /// Fetches installed model tags directly from Ollama.
    private static func fetchOllamaTags(backendURL: String) async throws -> Set<String> {
        guard let rootURL = URL(string: backendURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChatClientError.invalidURL
        }
        let endpoint = rootURL.appending(path: "api/tags")
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ChatClientError.emptyResponse
        }
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return Set(decoded.models.flatMap { [$0.name, $0.model] })
    }

    /// Single-quote escaping for generated shell scripts.
    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
