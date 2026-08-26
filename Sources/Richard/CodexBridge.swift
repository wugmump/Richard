import Foundation

/// Result returned after attempting to queue a message into Codex.
struct CodexBridgeResult {
    /// Process exit status from `codex queue`.
    let exitCode: Int32
    /// Combined stdout/stderr text.
    let output: String
}

/// Sends Richard-prefixed development notes into the configured Codex task.
enum CodexBridge {
    /// Queues one user note through the Codex CLI.
    @MainActor
    static func queue(
        note: String,
        author: String?,
        settings: AppSettings
    ) async -> CodexBridgeResult {
        let codexPath = settings.codexBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = settings.codexThreadID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !codexPath.isEmpty else {
            return CodexBridgeResult(exitCode: 2, output: "Codex CLI path is empty.")
        }
        guard !threadID.isEmpty else {
            return CodexBridgeResult(exitCode: 2, output: "Codex thread ID is empty.")
        }

        let port = settings.remotePort
        let joinCode = settings.remoteJoinCode
        let payload = bridgePrompt(note: note, author: author, port: port, joinCode: joinCode)

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: codexPath)
            process.arguments = [
                "queue",
                "--thread", threadID,
                "--message", payload
            ]
            let supportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appending(path: "Richard")
                .appending(path: "CodexBridge")
            if let supportDirectory {
                try? FileManager.default.createDirectory(
                    at: supportDirectory,
                    withIntermediateDirectories: true
                )
                process.currentDirectoryURL = supportDirectory
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return CodexBridgeResult(exitCode: process.terminationStatus, output: output)
            } catch {
                return CodexBridgeResult(exitCode: 1, output: error.localizedDescription)
            }
        }.value
    }

    /// Builds the message queued into this Codex task.
    ///
    /// The instruction includes the local callback endpoint so Codex can place
    /// its answer back into the Richard transcript after completing the work.
    private static func bridgePrompt(note: String, author: String?, port: Int, joinCode: String) -> String {
        let speaker = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySpeaker = speaker?.isEmpty == false ? speaker! : "Richard user"
        return """
        Richard bridge message from \(displaySpeaker). The user typed this after `Codex:` in the Richard app. Treat the following text as the user's verbatim development request:

        \(note)

        Work in `/Users/josh/Documents/Richard` unless the request says otherwise. When you are done, also send a concise reply back to Richard with:

        curl -s http://127.0.0.1:\(port)/api/codex-reply \\
          -H 'Content-Type: application/json' \\
          -H 'X-Richard-Code: \(joinCode)' \\
          -d '{"author":"Codex","content":"YOUR_REPLY_HERE","code":"\(joinCode)"}'

        Escape JSON correctly if the reply contains quotes or newlines. Keep the normal Codex final answer concise too.
        """
    }
}
