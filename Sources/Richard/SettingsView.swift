import SwiftUI

/// macOS Settings window for model, remote access, Pi, and age-gate options.
struct SettingsView: View {
    /// Shared app settings edited by this form.
    @EnvironmentObject private var settings: AppSettings
    /// Tracks which model install command was most recently copied.
    @State private var copiedCommand: String?
    /// Local Ollama setup checker/downloader.
    @StateObject private var ollamaManager = OllamaModelManager()
    /// Local Ollama setup checker/downloader for the image-analysis model.
    @StateObject private var visionModelManager = OllamaModelManager()

    /// Builds a grouped settings form.
    var body: some View {
        Form {
            Section("Recommended Models") {
                ForEach(ModelProfile.all) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.headline)
                                Text(profile.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                settings.apply(profile: profile)
                            } label: {
                                Label("Use", systemImage: "checkmark.circle")
                            }
                        }

                        LabeledContent("Quant", value: profile.quantization)
                        LabeledContent("Footprint", value: profile.footprint)
                        Text(profile.context)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(profile.installCommand)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)

                            Spacer()

                            Button {
                                // Copy rather than execute so the user keeps
                                // control over long model downloads.
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(profile.installCommand, forType: .string)
                                copiedCommand = profile.id
                            } label: {
                                Image(systemName: copiedCommand == profile.id ? "checkmark" : "doc.on.doc")
                            }
                            .help("Copy install command")

                            Link(destination: profile.sourceURL) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help("Open model page")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Section("Model Backend") {
                // Backend settings are intentionally raw and visible; this app
                // is designed for local model experimentation.
                Picker("Backend", selection: $settings.backendKind) {
                    ForEach(BackendKind.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Backend URL", text: $settings.backendURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $settings.modelName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Label(ollamaManager.state.label, systemImage: modelStatusIcon)
                        .foregroundStyle(modelStatusColor)

                    Spacer()

                    Button {
                        Task { await ollamaManager.check(settings: settings) }
                    } label: {
                        Label("Check", systemImage: "arrow.clockwise")
                    }
                    .disabled(settings.backendKind != .ollama || ollamaManager.state.isBusy)

                    Button {
                        Task { await ollamaManager.pull(settings: settings) }
                    } label: {
                        Label("Install Model", systemImage: "square.and.arrow.down")
                    }
                    .disabled(settings.backendKind != .ollama || ollamaManager.state.isBusy)
                }

                Text("The install button uses Ollama's local `/api/pull` endpoint. Ollama must be installed and running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vision Model") {
                TextField("Image model", text: $settings.visionModelName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Label(visionModelManager.state.label, systemImage: visionStatusIcon)
                        .foregroundStyle(visionStatusColor)

                    Spacer()

                    Button {
                        Task {
                            await visionModelManager.check(
                                backendURL: settings.backendURL,
                                modelName: settings.visionModelName
                            )
                        }
                    } label: {
                        Label("Check", systemImage: "arrow.clockwise")
                    }
                    .disabled(settings.backendKind != .ollama || visionModelManager.state.isBusy)

                    Button {
                        Task {
                            await visionModelManager.pull(
                                backendURL: settings.backendURL,
                                modelName: settings.visionModelName
                            )
                        }
                    } label: {
                        Label("Install Vision Model", systemImage: "photo.badge.arrow.down")
                    }
                    .disabled(settings.backendKind != .ollama || visionModelManager.state.isBusy)
                }

                Text("Default: `qwen2.5vl:7b`. Richard can request image parsing with `IMAGE_ANALYZE: /absolute/path.png`, and Pi screenshots are analyzed automatically when possible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote Access") {
                // These values drive `RemoteChatServer`, which watches settings
                // changes and restarts itself when needed.
                Toggle("Allow office users to join one shared chat", isOn: $settings.remoteAccessEnabled)

                Toggle("Serve with HTTPS", isOn: $settings.remoteHTTPS)

                Stepper(value: $settings.remotePort, in: 1024...65535) {
                    LabeledContent("Port", value: "\(settings.remotePort)")
                }

                TextField("Join code", text: $settings.remoteJoinCode)
                    .textFieldStyle(.roundedBorder)

                TextField("TLS .p12 identity path", text: $settings.tlsIdentityPath)
                    .textFieldStyle(.roundedBorder)

                SecureField("TLS .p12 password", text: $settings.tlsIdentityPassword)
                    .textFieldStyle(.roundedBorder)

                Text("HTTPS requires a certificate packaged as a PKCS#12 .p12 identity. For quick internal testing, turn HTTPS off or use a local reverse proxy with a trusted office certificate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Share URL", value: settings.shareURL)
            }

            Section("Raspberry Pi") {
                // The Pi credentials are currently stored in defaults because
                // this is a local private tool, but they are surfaced here so
                // the hardcoded defaults can be changed without rebuilding.
                TextField("Host", text: $settings.raspberryPiHost)
                    .textFieldStyle(.roundedBorder)

                TextField("User", text: $settings.raspberryPiUser)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $settings.raspberryPiPassword)
                    .textFieldStyle(.roundedBorder)

                Stepper(value: $settings.raspberryPiPort, in: 1...65535) {
                    LabeledContent("SSH Port", value: "\(settings.raspberryPiPort)")
                }

                Text("Richard runs commands with `/usr/bin/ssh`. For USB-C control, configure the Pi as a USB network gadget or otherwise make SSH reachable from this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Codex Bridge") {
                TextField("Codex CLI", text: $settings.codexBinaryPath)
                    .textFieldStyle(.roundedBorder)

                TextField("Codex Thread ID", text: $settings.codexThreadID)
                    .textFieldStyle(.roundedBorder)

                Text("Messages that begin with `Codex:` are queued into this Codex task. Codex can post the answer back through Richard's local `/api/codex-reply` endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Access") {
                // Lets the user re-open the age gate state during development.
                Toggle("Age verified", isOn: $settings.isAgeVerified)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await ollamaManager.check(settings: settings)
            await visionModelManager.check(backendURL: settings.backendURL, modelName: settings.visionModelName)
        }
        .onChange(of: settings.modelName) { _, _ in
            Task { await ollamaManager.check(settings: settings) }
        }
        .onChange(of: settings.backendURL) { _, _ in
            Task { await ollamaManager.check(settings: settings) }
        }
        .onChange(of: settings.backendKind) { _, _ in
            Task { await ollamaManager.check(settings: settings) }
        }
        .onChange(of: settings.visionModelName) { _, _ in
            Task {
                await visionModelManager.check(
                    backendURL: settings.backendURL,
                    modelName: settings.visionModelName
                )
            }
        }
    }

    /// SF Symbol matching the current Ollama model state.
    private var modelStatusIcon: String {
        switch ollamaManager.state {
        case .installed: "checkmark.circle.fill"
        case .pulling: "arrow.down.circle"
        case .missing: "exclamationmark.circle"
        case .unreachable, .failed: "xmark.octagon"
        case .unknown: "questionmark.circle"
        }
    }

    /// Color matching the current Ollama model state.
    private var modelStatusColor: Color {
        switch ollamaManager.state {
        case .installed: .green
        case .pulling: .blue
        case .missing, .unknown: .secondary
        case .unreachable, .failed: .red
        }
    }

    /// SF Symbol matching the current vision model state.
    private var visionStatusIcon: String {
        switch visionModelManager.state {
        case .installed: "checkmark.circle.fill"
        case .pulling: "arrow.down.circle"
        case .missing: "exclamationmark.circle"
        case .unreachable, .failed: "xmark.octagon"
        case .unknown: "questionmark.circle"
        }
    }

    /// Color matching the current vision model state.
    private var visionStatusColor: Color {
        switch visionModelManager.state {
        case .installed: .green
        case .pulling: .blue
        case .missing, .unknown: .secondary
        case .unreachable, .failed: .red
        }
    }
}
