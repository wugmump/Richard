import SwiftUI

/// Root view for the app. It keeps the age gate separate from the live chat
/// surface so the remote listener and model state only come up after consent.
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var remoteServer = RemoteChatServer()

    var body: some View {
        if settings.isAgeVerified {
            ChatShellView(viewModel: viewModel, remoteServer: remoteServer)
                .onAppear {
                    remoteServer.reconcile(viewModel: viewModel, settings: settings)
                }
                // The server binds directly to the selected listener settings,
                // so changes need a restart rather than passive state updates.
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
        } else {
            AgeGateView()
        }
    }
}

/// One-time local age confirmation. The flag is persisted in AppStorage by
/// AppSettings, so this view normally disappears after the first accepted run.
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
                Text("This app is for private, consensual fictional roleplay between adults. You must be 18 or older to continue.")
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

/// Primary application layout: a narrow operations sidebar plus the shared
/// transcript, status strip, and composer.
private struct ChatShellView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var remoteServer: RemoteChatServer

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel, remoteServer: remoteServer)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            VStack(spacing: 0) {
                MessageListView(messages: viewModel.messages)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.08))
                }

                if viewModel.isSending {
                    ThinkingStatusView(text: viewModel.statusText)
                }

                ComposerView(viewModel: viewModel)
                    .environmentObject(settings)
            }
            .navigationTitle(settings.modelName)
        }
    }
}

/// Inline progress indicator shown while the model, Pi command runner, or
/// screenshot capture is active. ChatViewModel updates the text periodically.
private struct ThinkingStatusView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text.isEmpty ? "Richard is thinking." : text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Operational sidebar for local backend status, remote access state, Pi command
/// testing, and destructive transcript reset.
private struct SidebarView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var remoteServer: RemoteChatServer
    @StateObject private var piController = RaspberryPiController()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Local Backend", systemImage: "cpu")
                    .font(.headline)
                Text(settings.backendKind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(settings.backendURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Remote Chat", systemImage: "network")
                    .font(.headline)
                Text(remoteServer.statusText)
                    .font(.caption)
                    .foregroundStyle(remoteServer.isRunning ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                if !settings.remoteJoinCode.isEmpty {
                    LabeledContent("Join Code", value: settings.remoteJoinCode)
                }
            }

            Divider()

            RaspberryPiPanel(controller: piController)
                .environmentObject(settings)

            Divider()

            Button(role: .destructive) {
                viewModel.reset()
            } label: {
                Label("Reset Chat", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

/// Small manual SSH console for the Raspberry Pi. It uses the same credentials
/// Richard uses internally, which makes preferences changes immediately testable.
private struct RaspberryPiPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var controller: RaspberryPiController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Raspberry Pi", systemImage: "terminal")
                .font(.headline)

            TextField("Host", text: $settings.raspberryPiHost)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("User", text: $settings.raspberryPiUser)
                    .textFieldStyle(.roundedBorder)

                Stepper(value: $settings.raspberryPiPort, in: 1...65535) {
                    Text("\(settings.raspberryPiPort)")
                        .frame(width: 52, alignment: .trailing)
                }
            }

            SecureField("Password", text: $settings.raspberryPiPassword)
                .textFieldStyle(.roundedBorder)

            TextField("Command", text: $controller.command)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    controller.run(settings: settings)
                }

            Button {
                controller.run(settings: settings)
            } label: {
                Label(controller.isRunning ? "Running" : "Run Command", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isRunning)

            ScrollView {
                Text(controller.output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 90, maxHeight: 150)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Scrollable transcript. A hidden bottom anchor avoids depending on the last
/// message height, and the delayed second scroll handles SwiftUI's first layout
/// pass when restoring a long saved history on launch.
private struct MessageListView: View {
    let messages: [ChatMessage]
    private let bottomID = "message-list-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(20)
            }
            .onChange(of: messages) { _, newMessages in
                guard !newMessages.isEmpty else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !messages.isEmpty else { return }

        DispatchQueue.main.async {
            proxy.scrollTo(bottomID, anchor: .bottom)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

/// Visual presentation for one chat message. Remote user messages show the
/// author label outside the colored bubble to keep attribution readable.
private struct MessageBubbleView: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 80) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if let author = message.author, !author.isEmpty {
                    Text("\(author) said:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(isUser ? .white : .primary)
                    .background(isUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let imagePaths = message.imagePaths, !imagePaths.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 8)],
                        alignment: isUser ? .trailing : .leading,
                        spacing: 8
                    ) {
                        ForEach(imagePaths, id: \.self) { path in
                            ChatImageThumbnail(path: path)
                        }
                    }
                    .frame(maxWidth: 380, alignment: isUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: 640, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 80) }
        }
    }
}

/// Thumbnail renderer for images saved by paste/upload handling.
private struct ChatImageThumbnail: View {
    let path: String

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 140, height: 96)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .help(path)
        }
    }
}

/// Local prompt composer. PromptTextEditor supplies the Return-to-send behavior
/// while keeping Shift-Return available for multi-line prompts.
private struct ComposerView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)

                if viewModel.draft.isEmpty {
                    Text("Message")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                }

                PromptTextEditor(text: $viewModel.draft) {
                    if !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isSending {
                        viewModel.send(settings: settings)
                    }
                } onPasteImages: { paths in
                    appendImageAnalysisDirectives(paths)
                }
                .frame(minHeight: 44, maxHeight: 120)
                .padding(.horizontal, 1)
            }
            .frame(minHeight: 44, maxHeight: 120)

            Button {
                viewModel.send(settings: settings)
            } label: {
                if viewModel.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .help("Send")
            .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
        }
        .padding(16)
        .background(.bar)
    }

    /// Adds pasted image attachments to the draft as local vision-tool
    /// directives, preserving any text the user already typed.
    private func appendImageAnalysisDirectives(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let directives = paths
            .map { "IMAGE_ANALYZE: \($0) | Describe this pasted image and mention any readable text or obvious UI state." }
            .joined(separator: "\n")

        let trimmedDraft = viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.draft = trimmedDraft.isEmpty ? directives : "\(viewModel.draft)\n\(directives)"
    }
}
