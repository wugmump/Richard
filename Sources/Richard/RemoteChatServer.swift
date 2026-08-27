import Foundation
import Network
import Security

/// Lightweight HTTP(S) server that exposes the same shared chat used by the
/// native app to other devices on the LAN.
///
/// This intentionally avoids a full web framework: Network.framework owns the
/// listener, and a small request parser is enough for the web page plus JSON API.
final class RemoteChatServer: ObservableObject, @unchecked Sendable {
    /// True while the Network.framework listener is ready.
    @Published private(set) var isRunning = false
    /// Human-readable listener state shown in the sidebar.
    @Published private(set) var statusText = "Remote access is off."
    /// Current share URL, also mirrored into settings for the menu copy command.
    @Published private(set) var publicURL = ""

    private var listener: NWListener?
    /// Serial queue for listener callbacks and socket reads.
    private let queue = DispatchQueue(label: "richard.remote-chat-server")
    /// Weak references avoid a retain cycle between SwiftUI state objects.
    private weak var viewModel: ChatViewModel?
    private weak var settings: AppSettings?

    /// Starts the listener if remote access is enabled and binds the current
    /// app state objects used for routing requests.
    @MainActor
    func reconcile(viewModel: ChatViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings

        guard settings.remoteAccessEnabled else {
            stop()
            return
        }

        if isRunning { return }
        start(settings: settings)
    }

    /// Rebinds the listener after settings that affect the socket or TLS change.
    @MainActor
    func restart(viewModel: ChatViewModel, settings: AppSettings) {
        stop()
        reconcile(viewModel: viewModel, settings: settings)
    }

    /// Tears down the listener and clears the share URL.
    @MainActor
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        publicURL = ""
        settings?.remotePublicURL = ""
        statusText = "Remote access is off."
    }

    /// Creates and starts the Network.framework listener.
    @MainActor
    private func start(settings: AppSettings) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(settings.remotePort)) else {
            statusText = "Remote port must be between 1 and 65535."
            return
        }

        do {
            let parameters = try makeParameters(settings: settings)
            let remotePort = settings.remotePort
            let remoteHTTPS = settings.remoteHTTPS
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handle(state: state, port: remotePort, https: remoteHTTPS)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            isRunning = false
            statusText = error.localizedDescription
        }
    }

    /// Builds TCP or TLS listener parameters from settings.
    ///
    /// If HTTPS is enabled without a certificate path, the app falls back to HTTP
    /// so remote chat still works during local development.
    @MainActor
    private func makeParameters(settings: AppSettings) throws -> NWParameters {
        guard settings.remoteHTTPS else {
            return .tcp
        }

        guard !settings.tlsIdentityPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            settings.remoteHTTPS = false
            statusText = "HTTPS needs a .p12 certificate. Falling back to HTTP."
            return .tcp
        }

        let tlsOptions = NWProtocolTLS.Options()
        let identity = try loadIdentity(path: settings.tlsIdentityPath, password: settings.tlsIdentityPassword)
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw RemoteServerError.tlsIdentityFailed
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, protocolIdentity)

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    /// Loads a PKCS#12 identity for Network.framework's TLS local identity.
    private func loadIdentity(path: String, password: String) throws -> SecIdentity {
        let url = URL(filePath: path)
        let data = try Data(contentsOf: url)
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var imported: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &imported)
        guard status == errSecSuccess,
              let items = imported as? [[String: Any]],
              let item = items.first,
              item[kSecImportItemIdentity as String] != nil else {
            throw RemoteServerError.tlsIdentityFailed
        }
        let identity = item[kSecImportItemIdentity as String] as! SecIdentity
        return identity
    }

    /// Mirrors listener state into UI-visible status and the copyable public URL.
    @MainActor
    private func handle(state: NWListener.State, port: Int, https: Bool) {
        switch state {
        case .ready:
            isRunning = true
            let scheme = https ? "https" : "http"
            publicURL = "\(scheme)://\(NetworkAddress.shareHost()):\(port)"
            settings?.remotePublicURL = publicURL
            statusText = "Listening at \(publicURL)"
        case .failed(let error):
            isRunning = false
            settings?.remotePublicURL = ""
            statusText = "Remote server failed: \(error.localizedDescription)"
        case .cancelled:
            isRunning = false
            publicURL = ""
            settings?.remotePublicURL = ""
            statusText = "Remote access is off."
        default:
            break
        }
    }

    /// Starts a new client connection and begins collecting the HTTP request.
    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads until a complete HTTP request is available.
    ///
    /// The request parser returns nil while headers or the declared body length
    /// are incomplete, so this function keeps appending chunks until routable.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.send(response: HTTPResponse(status: 400, body: error.localizedDescription), on: connection)
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = HTTPRequest(data: nextBuffer) {
                Task { @MainActor in
                    let response = await self.route(request: request)
                    self.send(response: response, on: connection)
                }
            } else if isComplete {
                self.send(response: HTTPResponse(status: 400, body: "Bad request"), on: connection)
            } else {
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    /// Maps the small public API onto the shared ChatViewModel.
    @MainActor
    private func route(request: HTTPRequest) async -> HTTPResponse {
        guard let viewModel, let settings else {
            return HTTPResponse(status: 503, body: "Chat is not ready.")
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Self.chatHTML)
        case ("GET", "/api/attachment"):
            guard isAuthorized(request: request, joinCode: settings.remoteJoinCode) else {
                return HTTPResponse(status: 401, body: "Unauthorized")
            }
            return Self.attachmentResponse(request: request)
        case ("GET", "/api/messages"):
            guard isAuthorized(request: request, joinCode: settings.remoteJoinCode) else {
                return HTTPResponse(status: 401, body: "Unauthorized")
            }
            return jsonResponse(RemoteMessagesResponse.make(
                messages: viewModel.messages,
                joinCode: settings.remoteJoinCode,
                isSending: viewModel.isSending,
                statusText: viewModel.statusText,
                activity: Array(viewModel.activityEvents.suffix(30)),
                assholeLevel: settings.assholeLevel
            ))
        case ("GET", "/api/activity"):
            guard isAuthorized(request: request, joinCode: settings.remoteJoinCode) else {
                return HTTPResponse(status: 401, body: "Unauthorized")
            }
            return jsonResponse(RemoteActivityResponse(
                isSending: viewModel.isSending,
                statusText: viewModel.statusText,
                activity: viewModel.activityEvents
            ))
        case ("POST", "/api/messages"):
            guard let incoming = try? JSONDecoder().decode(RemoteIncomingMessage.self, from: request.body) else {
                return HTTPResponse(status: 400, body: "Expected JSON body with content, author, and code.")
            }
            guard let author = incoming.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty else {
                return HTTPResponse(status: 400, body: "Remote messages require a name.")
            }
            guard isAuthorized(request: request, bodyCode: incoming.code, joinCode: settings.remoteJoinCode) else {
                return HTTPResponse(status: 401, body: "Unauthorized")
            }

            do {
                let content = try Self.contentWithSavedImages(from: incoming)
                let messages = try await viewModel.submit(text: content, author: author, settings: settings)
                return jsonResponse(RemoteMessagesResponse.make(
                messages: messages,
                joinCode: settings.remoteJoinCode,
                isSending: viewModel.isSending,
                statusText: viewModel.statusText,
                activity: Array(viewModel.activityEvents.suffix(30)),
                assholeLevel: settings.assholeLevel
            ))
            } catch {
                return HTTPResponse(status: 409, body: error.localizedDescription)
            }
        case ("POST", "/api/codex-reply"):
            guard let incoming = try? JSONDecoder().decode(RemoteCodexReply.self, from: request.body) else {
                return HTTPResponse(status: 400, body: "Expected JSON body with author, content, and code.")
            }
            guard isAuthorized(request: request, bodyCode: incoming.code, joinCode: settings.remoteJoinCode) else {
                return HTTPResponse(status: 401, body: "Unauthorized")
            }

            viewModel.appendCodexReply(
                content: incoming.content,
                author: incoming.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? incoming.author! : "Codex"
            )
            return jsonResponse(RemoteMessagesResponse.make(
                messages: viewModel.messages,
                joinCode: settings.remoteJoinCode,
                isSending: viewModel.isSending,
                statusText: viewModel.statusText,
                activity: Array(viewModel.activityEvents.suffix(30)),
                assholeLevel: settings.assholeLevel
            ))
        case ("POST", "/api/settings"):
            guard let incoming = try? JSONDecoder().decode(RemoteSettingsUpdate.self, from: request.body) else {
                return HTTPResponse(status: 400, body: "Expected JSON body with code and assholeLevel.")
            }
            guard isAuthorized(request: request, bodyCode: incoming.code, joinCode: settings.remoteJoinCode) else {
                return HTTPResponse(status: 401, body: "Unauthorized")
            }

            settings.setAssholeLevel(incoming.assholeLevel)
            return jsonResponse(RemoteSettingsResponse(assholeLevel: settings.assholeLevel))
        default:
            return HTTPResponse(status: 404, body: "Not found")
        }
    }

    /// Saves uploaded browser images and appends `IMAGE_ANALYZE` tool lines to
    /// the submitted text.
    private static func contentWithSavedImages(from incoming: RemoteIncomingMessage) throws -> String {
        let text = incoming.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageDirectives = try (incoming.images ?? []).compactMap { image -> String? in
            guard let data = image.decodedData else { return nil }
            let path = try ImageAttachmentStore.save(data: data, suggestedExtension: image.fileExtension)
            let question = image.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveQuestion = question?.isEmpty == false
                ? question!
                : !text.isEmpty
                    ? text
                : "Describe this pasted image and mention any readable text or obvious UI state."
            return "IMAGE_ANALYZE: \(path) | \(effectiveQuestion)"
        }

        guard !imageDirectives.isEmpty else { return text }
        return imageDirectives.joined(separator: "\n")
    }

    /// Serves saved chat attachment bytes to authenticated browser clients.
    private static func attachmentResponse(request: HTTPRequest) -> HTTPResponse {
        guard let rawPath = request.query["path"], !rawPath.isEmpty else {
            return HTTPResponse(status: 400, body: "Missing attachment path.")
        }

        let url = URL(fileURLWithPath: rawPath)
        guard Self.isAllowedAttachmentPath(url.path),
              let data = try? Data(contentsOf: url) else {
            return HTTPResponse(status: 404, body: "Attachment not found.")
        }

        return HTTPResponse(status: 200, contentType: Self.contentType(for: url.pathExtension), body: data)
    }

    /// Limits browser-served files to Richard-created image directories.
    private static func isAllowedAttachmentPath(_ path: String) -> Bool {
        let standardized = NSString(string: path).standardizingPath
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let allowedRoots = [
            appSupport.appending(path: "Richard/Attachments").path,
            appSupport.appending(path: "Richard/Screenshots").path
        ].map { NSString(string: $0).standardizingPath }

        return allowedRoots.contains { standardized.hasPrefix($0 + "/") }
    }

    /// MIME type for common pasted image formats.
    private static func contentType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        default: "image/png"
        }
    }

    /// Accepts the join code from an API header, query string, or JSON body.
    private func isAuthorized(request: HTTPRequest, bodyCode: String? = nil, joinCode: String) -> Bool {
        request.headers["x-richard-code"] == joinCode
            || request.query["code"] == joinCode
            || bodyCode == joinCode
    }

    /// Encodes API payloads with ISO-8601 dates for browser clients.
    private func jsonResponse<T: Encodable>(_ payload: T) -> HTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            return HTTPResponse(status: 200, contentType: "application/json", body: data)
        } catch {
            return HTTPResponse(status: 500, body: error.localizedDescription)
        }
    }

    /// Sends the full HTTP response and closes the short-lived connection.
    private func send(response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Self-contained browser client served to remote users.
    ///
    /// The first interaction is the required name prompt; after that, the name is
    /// kept in localStorage so repeat visitors remain attributed consistently.
    private static let chatHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Richard</title>
      <style>
        :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        body { margin: 0; background: Canvas; color: CanvasText; }
        main { max-width: 860px; margin: 0 auto; min-height: 100vh; display: grid; grid-template-rows: auto 1fr auto auto; }
        header { padding: 16px; border-bottom: 1px solid color-mix(in srgb, CanvasText 16%, transparent); }
        h1 { font-size: 20px; margin: 0; }
        #messages { padding: 18px; overflow: auto; display: flex; flex-direction: column; gap: 12px; }
        .msg { max-width: 78%; padding: 10px 12px; border-radius: 8px; white-space: pre-wrap; line-height: 1.4; }
        .assistant { align-self: flex-start; background: color-mix(in srgb, CanvasText 10%, transparent); }
        .user { align-self: flex-end; background: AccentColor; color: white; }
        .remoteUser { align-self: flex-end; max-width: 78%; display: grid; justify-items: end; gap: 4px; }
        .speaker { color: color-mix(in srgb, CanvasText 62%, transparent); font-size: 13px; }
        .remoteUser .msg { max-width: 100%; }
        .messageImages { display: flex; flex-wrap: wrap; gap: 8px; max-width: 100%; }
        .messageImages img { width: min(180px, 42vw); height: 120px; object-fit: cover; border-radius: 8px; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); }
        #composer { display: grid; grid-template-columns: auto minmax(0, 1fr) auto auto; gap: 10px; padding: 14px; border-top: 1px solid color-mix(in srgb, CanvasText 16%, transparent); }
        #attachButton, #settingsButton { width: 42px; padding: 0; display: grid; place-items: center; }
        #fileInput { display: none; }
        #attachments { grid-column: 1 / -1; display: none; flex-wrap: wrap; gap: 8px; }
        #attachments.visible { display: flex; }
        .attachment { display: inline-flex; align-items: center; gap: 6px; max-width: 240px; border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); border-radius: 8px; padding: 5px 8px; font-size: 13px; color: CanvasText; background: color-mix(in srgb, CanvasText 7%, transparent); }
        .attachment img { width: 28px; height: 28px; object-fit: cover; border-radius: 4px; }
        .attachment span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        #status { min-height: 18px; padding: 8px 14px 0; color: color-mix(in srgb, CanvasText 62%, transparent); font-size: 13px; }
        #status:empty { display: none; }
        dialog { width: min(420px, calc(100vw - 32px)); border: 1px solid color-mix(in srgb, CanvasText 22%, transparent); border-radius: 8px; padding: 0; background: Canvas; color: CanvasText; box-shadow: 0 20px 60px rgba(0,0,0,.35); }
        dialog::backdrop { background: rgba(0,0,0,.35); }
        #settingsHeader { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 14px 16px; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); }
        #settingsHeader h2 { margin: 0; font-size: 18px; }
        #closeSettingsButton { width: 34px; height: 34px; padding: 0; background: color-mix(in srgb, CanvasText 10%, transparent); color: CanvasText; }
        #settingsBody { display: grid; gap: 16px; padding: 16px; }
        #identitySettings { display: grid; gap: 8px; color: color-mix(in srgb, CanvasText 72%, transparent); font-size: 13px; }
        #settingsNameRow { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
        #settingsNameValue { color: CanvasText; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        #changeNameButton { justify-self: start; background: color-mix(in srgb, CanvasText 12%, transparent); color: CanvasText; }
        #behaviorPanel { display: grid; gap: 6px; color: color-mix(in srgb, CanvasText 72%, transparent); font-size: 13px; }
        #behaviorHeader { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
        #assholeValue { font-variant-numeric: tabular-nums; color: CanvasText; }
        #assholeSlider { width: 100%; accent-color: AccentColor; }
        #behaviorScale { display: flex; justify-content: space-between; gap: 10px; font-size: 12px; color: color-mix(in srgb, CanvasText 55%, transparent); }
        input, button { font: inherit; border-radius: 8px; border: 1px solid color-mix(in srgb, CanvasText 22%, transparent); padding: 10px 12px; }
        button { background: AccentColor; color: white; border: 0; }
        #identityGate { position: fixed; inset: 0; display: grid; place-items: center; background: color-mix(in srgb, Canvas 92%, CanvasText 8%); z-index: 10; }
        #identityGate.hidden { display: none; }
        #identityPanel { width: min(420px, calc(100vw - 32px)); display: grid; gap: 12px; }
        #identityPanel h2 { margin: 0; font-size: 24px; }
        #identityError { color: #ff453a; min-height: 20px; }
        header { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
        #identityLabel { font-size: 13px; color: color-mix(in srgb, CanvasText 62%, transparent); }
        #offlineBanner { display: none; position: fixed; inset: 0; z-index: 20; place-items: center; padding: 24px; background: color-mix(in srgb, Canvas 84%, CanvasText 16%); color: white; font-size: clamp(28px, 7vw, 56px); font-weight: 800; text-align: center; text-transform: uppercase; letter-spacing: 0; }
        #offlineBanner.visible { display: grid; }
      </style>
    </head>
    <body>
      <section id="identityGate" aria-modal="true">
        <form id="identityPanel">
          <h2>What's your name, jerkface?</h2>
          <input id="nameInput" autocomplete="name" autofocus>
          <button>Enter</button>
          <div id="identityError"></div>
        </form>
      </section>
      <main>
        <div id="offlineBanner" role="status" aria-live="polite">Richard is offline</div>
        <header>
          <h1>Richard</h1>
          <span id="identityLabel"></span>
        </header>
        <section id="messages"></section>
        <div id="status"></div>
        <form id="composer">
          <button id="attachButton" type="button" title="Attach image">+</button>
          <input id="fileInput" type="file" accept="image/*" multiple>
          <div id="attachments"></div>
          <input id="content" placeholder="Message" autocomplete="off">
          <button id="settingsButton" type="button" title="Settings" aria-label="Settings">⚙</button>
          <button id="sendButton" type="submit">Send</button>
        </form>
      </main>
      <dialog id="settingsDialog" aria-labelledby="settingsTitle">
        <div id="settingsHeader">
          <h2 id="settingsTitle">Settings</h2>
          <button id="closeSettingsButton" type="button" title="Close" aria-label="Close">×</button>
        </div>
        <div id="settingsBody">
          <section id="identitySettings" aria-label="Identity">
            <div id="settingsNameRow">
              <span>Name</span>
              <strong id="settingsNameValue"></strong>
            </div>
            <button id="changeNameButton" type="button">Change Name</button>
          </section>
          <section id="behaviorPanel" aria-label="Richard behavior">
            <div id="behaviorHeader">
              <span>Asshole Level</span>
              <strong id="assholeValue">50</strong>
            </div>
            <input id="assholeSlider" type="range" min="0" max="100" step="1" value="50">
            <div id="behaviorScale">
              <span>Fully obsequious</span>
              <span>Total asshole</span>
            </div>
          </section>
        </div>
      </dialog>
      <script>
        let userName = localStorage.richardName || "";
        var code = "";
        const gate = document.getElementById("identityGate");
        const nameInput = document.getElementById("nameInput");
        const identityError = document.getElementById("identityError");
        const identityLabel = document.getElementById("identityLabel");
        const content = document.getElementById("content");
        const messages = document.getElementById("messages");
        const status = document.getElementById("status");
        const offlineBanner = document.getElementById("offlineBanner");
        const sendButton = document.getElementById("sendButton");
        const settingsButton = document.getElementById("settingsButton");
        const settingsDialog = document.getElementById("settingsDialog");
        const closeSettingsButton = document.getElementById("closeSettingsButton");
        const changeNameButton = document.getElementById("changeNameButton");
        const fileInput = document.getElementById("fileInput");
        const attachments = document.getElementById("attachments");
        const assholeSlider = document.getElementById("assholeSlider");
        const assholeValue = document.getElementById("assholeValue");
        const settingsNameValue = document.getElementById("settingsNameValue");
        const attachedImages = [];
        let isOffline = false;
        let isSubmitting = false;
        let settingsSaveTimer = 0;
        let isEditingSettings = false;

        function requireName() {
          userName = userName.trim();
          if (!userName) {
            gate.classList.remove("hidden");
            nameInput.focus();
            return false;
          }

          localStorage.richardName = userName;
          identityLabel.textContent = userName;
          settingsNameValue.textContent = userName;
          gate.classList.add("hidden");
          return true;
        }

        function requireCode() {
          const params = new URLSearchParams(window.location.search);
          code = params.get("code") || sessionStorage.richardCode || prompt("Join code");
          sessionStorage.richardCode = code || "";
        }

        function render(items) {
          messages.innerHTML = "";
          for (const item of items) {
            if (item.role === "user" && item.author) {
              const wrapper = document.createElement("div");
              wrapper.className = "remoteUser";
              const speaker = document.createElement("div");
              speaker.className = "speaker";
              speaker.textContent = item.author + " said:";
              const bubble = document.createElement("div");
              bubble.className = "msg user";
              bubble.textContent = item.content;
              wrapper.appendChild(speaker);
              wrapper.appendChild(bubble);
              appendMessageImages(wrapper, item.imageURLs || []);
              messages.appendChild(wrapper);
              continue;
            }

            const div = document.createElement("div");
            div.className = "msg " + item.role;
            div.textContent = item.content;
            messages.appendChild(div);
            appendMessageImages(messages, item.imageURLs || []);
          }
          scrollMessagesToEnd();
        }

        function scrollMessagesToEnd() {
          messages.scrollTop = messages.scrollHeight;
          requestAnimationFrame(() => {
            messages.scrollTop = messages.scrollHeight;
            requestAnimationFrame(() => {
              messages.scrollTop = messages.scrollHeight;
            });
          });
        }

        function appendMessageImages(parent, imageURLs) {
          if (!imageURLs.length) return;
          const imageRow = document.createElement("div");
          imageRow.className = "messageImages";
          for (const url of imageURLs) {
            const image = document.createElement("img");
            image.src = url;
            image.loading = "lazy";
            image.addEventListener("load", scrollMessagesToEnd, { once: true });
            image.addEventListener("error", scrollMessagesToEnd, { once: true });
            imageRow.appendChild(image);
          }
          parent.appendChild(imageRow);
          scrollMessagesToEnd();
        }

        function renderState(payload) {
          setOffline(false);
          render(payload.messages || []);
          if (!isEditingSettings && typeof payload.assholeLevel === "number") {
            renderAssholeLevel(payload.assholeLevel);
          }
          status.textContent = payload.isSending ? (payload.statusText || "Richard is thinking.") : "";
        }

        function setOffline(value) {
          isOffline = value;
          offlineBanner.classList.toggle("visible", value);
          content.disabled = value;
          sendButton.disabled = value || isSubmitting;
          document.getElementById("attachButton").disabled = value;
          assholeSlider.disabled = value;
          if (value) status.textContent = "";
        }

        function setSubmitting(value) {
          isSubmitting = value;
          sendButton.disabled = value || isOffline;
        }

        function renderAssholeLevel(value) {
          const normalized = Math.max(0, Math.min(100, Math.round(Number(value) || 0)));
          assholeSlider.value = String(normalized);
          assholeValue.textContent = String(normalized);
        }

        function scheduleSettingsSave() {
          clearTimeout(settingsSaveTimer);
          const level = Number(assholeSlider.value);
          renderAssholeLevel(level);
        }

        async function saveSettings(level) {
          if (!code) requireCode();
          try {
            const res = await fetch("/api/settings", {
              method: "POST",
              headers: { "Content-Type": "application/json", "X-Richard-Code": code },
              body: JSON.stringify({ code, assholeLevel: level })
            });
            if (res.ok) {
              const payload = await res.json();
              if (typeof payload.assholeLevel === "number") renderAssholeLevel(payload.assholeLevel);
              setOffline(false);
            } else if (res.status >= 500) {
              setOffline(true);
            }
          } catch (_) {
            setOffline(true);
          } finally {
            isEditingSettings = false;
          }
        }

        function renderAttachments() {
          attachments.innerHTML = "";
          attachments.classList.toggle("visible", attachedImages.length > 0);
          for (const image of attachedImages) {
            const item = document.createElement("div");
            item.className = "attachment";
            const preview = document.createElement("img");
            preview.src = image.preview;
            const label = document.createElement("span");
            label.textContent = image.name;
            item.appendChild(preview);
            item.appendChild(label);
            attachments.appendChild(item);
          }
        }

        function readFileAsDataURL(file) {
          return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result || ""));
            reader.onerror = () => reject(reader.error || new Error("Read failed"));
            reader.readAsDataURL(file);
          });
        }

        async function attachFiles(files) {
          for (const file of files) {
            if (!file.type.startsWith("image/")) continue;
            const dataURL = await readFileAsDataURL(file);
            attachedImages.push({
              name: file.name || "pasted-image.png",
              mimeType: file.type || "image/png",
              data: dataURL,
              preview: dataURL
            });
          }
          renderAttachments();
        }

        async function refresh() {
          if (!userName || !code) return;
          try {
            const res = await fetch("/api/messages?code=" + encodeURIComponent(code), { cache: "no-store" });
            if (res.ok) {
              renderState(await res.json());
            } else if (res.status >= 500) {
              setOffline(true);
            }
          } catch (_) {
            setOffline(true);
          }
        }

        document.getElementById("identityPanel").addEventListener("submit", event => {
          event.preventDefault();
          userName = nameInput.value.trim();
          if (!userName) {
            identityError.textContent = "Type a name. This is not optional.";
            nameInput.focus();
            return;
          }
          identityError.textContent = "";
          requireName();
          requireCode();
          refresh();
          content.focus();
        });

        document.getElementById("composer").addEventListener("submit", async event => {
          event.preventDefault();
          if (isSubmitting) return;
          if (!requireName()) return;
          if (!code) requireCode();
          const text = content.value.trim();
          if (!text && attachedImages.length === 0) return;
          setSubmitting(true);
          content.value = "";
          const images = attachedImages.splice(0, attachedImages.length).map(image => ({
            name: image.name,
            mimeType: image.mimeType,
            data: image.data
          }));
          renderAttachments();
          try {
            const res = await fetch("/api/messages", {
              method: "POST",
              headers: { "Content-Type": "application/json", "X-Richard-Code": code },
              body: JSON.stringify({ author: userName, content: text, code, images })
            });
            if (res.ok) {
              renderState(await res.json());
            } else if (res.status >= 500) {
              setOffline(true);
            }
          } catch (_) {
            setOffline(true);
            content.value = text;
            attachedImages.push(...images.map(image => ({ ...image, preview: image.data })));
            renderAttachments();
          } finally {
            setSubmitting(false);
          }
        });

        document.getElementById("attachButton").addEventListener("click", () => fileInput.click());
        settingsButton.addEventListener("click", () => {
          if (typeof settingsDialog.showModal === "function") {
            settingsDialog.showModal();
          } else {
            settingsDialog.setAttribute("open", "");
          }
        });
        closeSettingsButton.addEventListener("click", () => settingsDialog.close());
        settingsDialog.addEventListener("click", event => {
          if (event.target === settingsDialog) settingsDialog.close();
        });
        changeNameButton.addEventListener("click", () => {
          settingsDialog.close();
          nameInput.value = userName;
          gate.classList.remove("hidden");
          nameInput.focus();
          nameInput.select();
        });
        fileInput.addEventListener("change", async () => {
          await attachFiles(fileInput.files || []);
          fileInput.value = "";
        });
        content.addEventListener("paste", async event => {
          const files = Array.from(event.clipboardData?.files || []).filter(file => file.type.startsWith("image/"));
          if (files.length === 0) return;
          event.preventDefault();
          await attachFiles(files);
        });
        assholeSlider.addEventListener("input", () => {
          isEditingSettings = true;
          scheduleSettingsSave();
        });
        assholeSlider.addEventListener("change", () => {
          isEditingSettings = true;
          clearTimeout(settingsSaveTimer);
          saveSettings(Number(assholeSlider.value));
        });

        if (requireName()) {
          requireCode();
          refresh();
        }
        window.addEventListener("load", scrollMessagesToEnd);
        setInterval(refresh, 2000);
      </script>
    </body>
    </html>
    """
}

/// Localized setup errors for HTTPS listener configuration.
private enum RemoteServerError: LocalizedError {
    case missingTLSIdentity
    case tlsIdentityFailed

    var errorDescription: String? {
        switch self {
        case .missingTLSIdentity:
            "HTTPS requires a PKCS#12 .p12 identity path and password in Remote Access settings."
        case .tlsIdentityFailed:
            "Could not load the TLS identity. Check the .p12 path and password."
        }
    }
}

/// JSON body accepted by `POST /api/messages`.
private struct RemoteIncomingMessage: Decodable {
    let author: String?
    let content: String
    let code: String?
    let images: [RemoteIncomingImage]?
}

/// Base64 image uploaded by the browser client.
private struct RemoteIncomingImage: Decodable {
    let name: String?
    let mimeType: String?
    let data: String
    let prompt: String?

    /// Decoded bytes from either raw base64 or a `data:image/...;base64,` URL.
    var decodedData: Data? {
        let payload: String
        if let comma = data.firstIndex(of: ",") {
            payload = String(data[data.index(after: comma)...])
        } else {
            payload = data
        }
        return Data(base64Encoded: payload)
    }

    /// Best-effort extension derived from MIME type or filename.
    var fileExtension: String {
        if let mimeType {
            switch mimeType.lowercased() {
            case "image/jpeg", "image/jpg": return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/heic": return "heic"
            case "image/heif": return "heif"
            default: break
            }
        }

        if let ext = name?.split(separator: ".").last, !ext.isEmpty {
            return String(ext)
        }

        return "png"
    }
}

/// JSON body accepted by `POST /api/codex-reply`.
private struct RemoteCodexReply: Decodable {
    let author: String?
    let content: String
    let code: String?
}

/// Browser request for updating live app settings.
private struct RemoteSettingsUpdate: Decodable {
    let code: String?
    let assholeLevel: Double
}

/// Browser response containing settings accepted by the app.
private struct RemoteSettingsResponse: Encodable {
    let assholeLevel: Double
}

/// Snapshot returned to browser clients for transcript polling.
private struct RemoteMessagesResponse: Encodable {
    let messages: [RemoteChatMessage]
    let isSending: Bool
    let statusText: String
    let activity: [ActivityEvent]
    let assholeLevel: Double

    /// Builds a browser-safe response from native transcript messages.
    static func make(
        messages: [ChatMessage],
        joinCode: String,
        isSending: Bool,
        statusText: String,
        activity: [ActivityEvent],
        assholeLevel: Double
    ) -> RemoteMessagesResponse {
        RemoteMessagesResponse(
            messages: messages.map { RemoteChatMessage(message: $0, joinCode: joinCode) },
            isSending: isSending,
            statusText: statusText,
            activity: activity,
            assholeLevel: assholeLevel
        )
    }
}

/// Browser-facing message DTO with image URLs instead of raw local paths.
private struct RemoteChatMessage: Encodable {
    let id: UUID
    let role: ChatMessage.Role
    let author: String?
    let content: String
    let imageURLs: [String]?
    let createdAt: Date

    init(message: ChatMessage, joinCode: String) {
        id = message.id
        role = message.role
        author = message.author
        content = message.content
        imageURLs = message.imagePaths?.map {
            "/api/attachment?code=\(Self.urlEncoded(joinCode))&path=\(Self.urlEncoded($0))"
        }
        createdAt = message.createdAt
    }

    /// Percent-encodes values for query-string use.
    private static func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

/// Diagnostic feed returned by `/api/activity`.
private struct RemoteActivityResponse: Encodable {
    let isSending: Bool
    let statusText: String
    let activity: [ActivityEvent]
}

/// Minimal HTTP request parser for the small LAN-facing API.
private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Returns nil until the byte buffer contains complete headers and the full
    /// body declared by Content-Length.
    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            parsedHeaders[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerRange.upperBound
        let expectedBodyLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + expectedBodyLength else { return nil }

        method = requestParts[0]
        let target = requestParts[1]
        let splitTarget = target.split(separator: "?", maxSplits: 1).map(String.init)
        path = splitTarget.first ?? "/"
        query = HTTPRequest.parseQuery(splitTarget.count > 1 ? splitTarget[1] : "")
        headers = parsedHeaders
        body = data[bodyStart..<(bodyStart + expectedBodyLength)]
    }

    /// Parses percent-encoded query parameters without pulling in URLComponents,
    /// because the request target here is only a path plus optional query string.
    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            let value = parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" : ""
            result[key] = value
        }
        return result
    }
}

/// Small HTTP response builder with the headers browsers need for this app.
private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    init(status: Int, contentType: String = "text/plain; charset=utf-8", body: String) {
        self.status = status
        self.contentType = contentType
        self.body = Data(body.utf8)
    }

    init(status: Int, contentType: String = "text/plain; charset=utf-8", body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    /// Serialized HTTP/1.1 response bytes.
    var data: Data {
        var response = Data()
        response.append("HTTP/1.1 \(status) \(reason)\r\n".data(using: .utf8)!)
        response.append("Content-Type: \(contentType)\r\n".data(using: .utf8)!)
        response.append("Content-Length: \(body.count)\r\n".data(using: .utf8)!)
        response.append("Connection: close\r\n".data(using: .utf8)!)
        response.append("Cache-Control: no-store\r\n\r\n".data(using: .utf8)!)
        response.append(body)
        return response
    }

    /// Reason phrases for the status codes used by the API.
    private var reason: String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Response"
        }
    }
}
