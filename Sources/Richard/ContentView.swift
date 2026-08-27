import AppKit
import SwiftUI

/// Root host view for the headless Richard runtime.
///
/// The macOS app no longer exposes a local chat transcript or composer. It
/// exists as a small control surface for age confirmation, server status,
/// share/join details, preferences, and transcript reset while all chat traffic
/// happens through the browser client served by `RemoteChatServer`.
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var remoteServer = RemoteChatServer()
    @StateObject private var setupManager = RuntimeSetupManager()

    var body: some View {
        Group {
            if settings.isAgeVerified {
                HeadlessHostView(viewModel: viewModel, remoteServer: remoteServer, setupManager: setupManager)
            } else {
                AgeGateView()
            }
        }
        .onAppear {
            guard settings.isAgeVerified else { return }
            remoteServer.reconcile(viewModel: viewModel, settings: settings)
            Task { await setupManager.prepareAndCheck(settings: settings) }
        }
        // Listener-affecting settings need an explicit server rebind. Keeping
        // these watches at the root means remote access stays alive even though
        // the Mac UI is no longer the primary chat interface.
        .onChange(of: settings.isAgeVerified) { _, isVerified in
            if isVerified {
                remoteServer.reconcile(viewModel: viewModel, settings: settings)
                Task { await setupManager.prepareAndCheck(settings: settings) }
            } else {
                remoteServer.stop()
            }
        }
        .onChange(of: settings.remoteAccessEnabled) { _, _ in
            remoteServer.restart(viewModel: viewModel, settings: settings)
        }
        .onChange(of: settings.remoteHTTPS) { _, _ in
            remoteServer.restart(viewModel: viewModel, settings: settings)
        }
        .onChange(of: settings.remotePort) { _, _ in
            remoteServer.restart(viewModel: viewModel, settings: settings)
        }
        .onChange(of: settings.tlsIdentityPath) { _, _ in
            remoteServer.restart(viewModel: viewModel, settings: settings)
        }
        .onChange(of: settings.tlsIdentityPassword) { _, _ in
            remoteServer.restart(viewModel: viewModel, settings: settings)
        }
        .onChange(of: settings.backendURL) { _, _ in
            Task { await setupManager.prepareAndCheck(settings: settings) }
        }
        .onChange(of: settings.backendKind) { _, _ in
            Task { await setupManager.prepareAndCheck(settings: settings) }
        }
        .onChange(of: settings.modelName) { _, _ in
            Task { await setupManager.prepareAndCheck(settings: settings) }
        }
        .onChange(of: settings.visionModelName) { _, _ in
            Task { await setupManager.prepareAndCheck(settings: settings) }
        }
        .onChange(of: settings.codexBinaryPath) { _, _ in
            Task { await setupManager.prepareAndCheck(settings: settings) }
        }
    }
}

/// One-time local age confirmation. The flag is persisted in `AppSettings`, so
/// this view normally appears only on first launch or during development reset.
private struct AgeGateView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 54))
                .foregroundStyle(.teal)

            VStack(spacing: 8) {
                Text("Richard")
                    .font(.largeTitle.bold())
                Text("This app hosts a private browser-based chat for adults. Confirm age before starting the local server.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button {
                settings.isAgeVerified = true
            } label: {
                Label("I am 18 or older", systemImage: "checkmark.circle.fill")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

/// Minimal native control panel for the server-only Richard runtime.
private struct HeadlessHostView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var remoteServer: RemoteChatServer
    @ObservedObject var setupManager: RuntimeSetupManager
    @State private var archiveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            remoteAccessPanel
            runtimePanel
            archivePanel
            setupPanel
            actions
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Compact title/status block that makes clear the Mac app is just the host.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Richard Host", systemImage: "server.rack")
                .font(.largeTitle.bold())
            Text("Headless runtime is active. Use the browser client for chat.")
                .foregroundStyle(.secondary)
        }
    }

    /// Connection information needed by office users to join the shared chat.
    private var remoteAccessPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Join Info", systemImage: remoteServer.isRunning ? "network" : "wifi.exclamationmark")
                .font(.headline)

            LabeledContent("Server") {
                Text(remoteServer.statusText)
                    .foregroundStyle(remoteServer.isRunning ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }

            LabeledContent("URL") {
                Text(settings.shareURL)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            LabeledContent("Join Code") {
                Text(settings.remoteJoinCode)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Live backend and generation status surfaced without exposing chat text.
    private var runtimePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Runtime", systemImage: "cpu")
                .font(.headline)

            LabeledContent("Backend", value: settings.backendKind.label)
            LabeledContent("Model", value: settings.modelName)
            LabeledContent("Asshole Level", value: "\(Int(settings.assholeLevel.rounded()))")
            LabeledContent("Readiness") {
                Label(
                    setupManager.requiredReady ? "Ready" : "Needs setup",
                    systemImage: setupManager.requiredReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(setupManager.requiredReady ? Color.green : Color.orange)
            }

            if viewModel.isSending {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.statusText.isEmpty ? "Richard is thinking." : viewModel.statusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Import/export controls for moving Richard history to another machine.
    private var archivePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("History Archive", systemImage: "archivebox")
                .font(.headline)

            Text("Export or restore the shared transcript, per-user memory, settings, uploaded images, screenshots, and generated setup files.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    exportArchive()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button {
                    importArchive()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.bordered)

            if let archiveStatus {
                Text(archiveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Startup setup scripts plus the dependency checks run on every launch.
    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Setup Checks", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                if setupManager.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await setupManager.prepareAndCheck(settings: settings) }
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
            }

            if let setupScriptURL = setupManager.setupScriptURL,
               let checkScriptURL = setupManager.checkScriptURL {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Setup Script") {
                        Text(setupScriptURL.path)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Check Script") {
                        Text(checkScriptURL.path)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(setupManager.checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: checkIcon(for: check))
                            .foregroundStyle(checkColor(for: check))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    if let setupDirectory = setupManager.setupDirectory {
                        NSWorkspace.shared.open(setupDirectory)
                    }
                } label: {
                    Label("Show Scripts", systemImage: "folder")
                }
                .disabled(setupManager.setupDirectory == nil)

                Button {
                    if let setupScriptURL = setupManager.setupScriptURL {
                        NSWorkspace.shared.open(setupScriptURL)
                    }
                } label: {
                    Label("Run Setup", systemImage: "play.fill")
                }
                .disabled(setupManager.setupScriptURL == nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Host-level commands that remain useful without a native chat surface.
    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                copy(settings.shareURL)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }

            Button {
                NSWorkspace.shared.open(URL(string: settings.shareURL)!)
            } label: {
                Label("Open Web Client", systemImage: "safari")
            }
            .disabled(settings.shareURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            SettingsLink {
                Label("Preferences", systemImage: "gearshape")
            }

            Button(role: .destructive) {
                viewModel.reset()
            } label: {
                Label("Reset Shared Chat", systemImage: "arrow.counterclockwise")
            }
        }
        .buttonStyle(.bordered)
    }

    /// Copies small strings such as the share URL into the macOS pasteboard.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Prompts for an archive destination and writes the portable history file.
    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Richard-\(Self.archiveDateStamp()).richardarchive"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try RichardArchiveManager.exportArchive(to: url)
            archiveStatus = "Exported \(url.path)"
        } catch {
            archiveStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Prompts for an archive, restores it, and refreshes live runtime state.
    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try RichardArchiveManager.importArchive(from: url)
            settings.reloadFromDefaults()
            viewModel.reloadTranscript()
            remoteServer.restart(viewModel: viewModel, settings: settings)
            Task { await setupManager.prepareAndCheck(settings: settings) }
            archiveStatus = "Imported \(url.path)"
        } catch {
            archiveStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Filesystem-safe timestamp for archive filenames.
    private static func archiveDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Symbol for a startup dependency row.
    private func checkIcon(for check: RuntimeSetupCheck) -> String {
        if check.isReady { return "checkmark.circle.fill" }
        return check.isOptional ? "exclamationmark.circle" : "xmark.octagon.fill"
    }

    /// Color for a startup dependency row.
    private func checkColor(for check: RuntimeSetupCheck) -> Color {
        if check.isReady { return .green }
        return check.isOptional ? .orange : .red
    }
}
