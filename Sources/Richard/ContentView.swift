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

    var body: some View {
        Group {
            if settings.isAgeVerified {
                HeadlessHostView(viewModel: viewModel, remoteServer: remoteServer)
            } else {
                AgeGateView()
            }
        }
        .onAppear {
            guard settings.isAgeVerified else { return }
            remoteServer.reconcile(viewModel: viewModel, settings: settings)
        }
        // Listener-affecting settings need an explicit server rebind. Keeping
        // these watches at the root means remote access stays alive even though
        // the Mac UI is no longer the primary chat interface.
        .onChange(of: settings.isAgeVerified) { _, isVerified in
            if isVerified {
                remoteServer.reconcile(viewModel: viewModel, settings: settings)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            remoteAccessPanel
            runtimePanel
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
}
