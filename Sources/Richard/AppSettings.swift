import Foundation

/// User-configurable settings shared across the app.
///
/// Every persisted property writes through to `UserDefaults` in `didSet`, so the
/// UI can bind directly to these values without separate save buttons.
@MainActor
final class AppSettings: ObservableObject {
    /// Whether the local user has passed the adult-use gate.
    @Published var isAgeVerified: Bool {
        didSet { UserDefaults.standard.set(isAgeVerified, forKey: Keys.isAgeVerified) }
    }

    /// Base URL for the selected model backend.
    @Published var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: Keys.backendURL) }
    }

    /// Backend protocol family.
    @Published var backendKind: BackendKind {
        didSet { UserDefaults.standard.set(backendKind.rawValue, forKey: Keys.backendKind) }
    }

    /// Model identifier passed to the backend.
    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: Keys.modelName) }
    }

    /// Ollama vision model used for local image analysis tools.
    @Published var visionModelName: String {
        didSet { UserDefaults.standard.set(visionModelName, forKey: Keys.visionModelName) }
    }

    /// Roleplay safeword recognized by `ChatViewModel`.
    @Published var safeword: String {
        didSet { UserDefaults.standard.set(safeword, forKey: Keys.safeword) }
    }

    /// Personality intensity from 0, fully obsequious, to 100, total asshole.
    @Published var assholeLevel: Double {
        didSet {
            let clamped = Self.clampedAssholeLevel(assholeLevel)
            guard assholeLevel == clamped else {
                assholeLevel = clamped
                return
            }
            UserDefaults.standard.set(assholeLevel, forKey: Keys.assholeLevel)
        }
    }

    /// Reserved explicit-roleplay flag kept for future UI/prompt options.
    @Published var allowExplicitRoleplay: Bool {
        didSet { UserDefaults.standard.set(allowExplicitRoleplay, forKey: Keys.allowExplicitRoleplay) }
    }

    /// Controls whether the LAN web chat server runs.
    @Published var remoteAccessEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteAccessEnabled, forKey: Keys.remoteAccessEnabled) }
    }

    /// Controls whether `RemoteChatServer` attempts to use TLS directly.
    @Published var remoteHTTPS: Bool {
        didSet { UserDefaults.standard.set(remoteHTTPS, forKey: Keys.remoteHTTPS) }
    }

    /// TCP port for the remote web chat server.
    @Published var remotePort: Int {
        didSet { UserDefaults.standard.set(remotePort, forKey: Keys.remotePort) }
    }

    /// Shared join code required by the web client and JSON APIs.
    @Published var remoteJoinCode: String {
        didSet { UserDefaults.standard.set(remoteJoinCode, forKey: Keys.remoteJoinCode) }
    }

    /// Optional PKCS#12 identity path for direct HTTPS serving.
    @Published var tlsIdentityPath: String {
        didSet { UserDefaults.standard.set(tlsIdentityPath, forKey: Keys.tlsIdentityPath) }
    }

    /// Password for the PKCS#12 identity.
    @Published var tlsIdentityPassword: String {
        didSet { UserDefaults.standard.set(tlsIdentityPassword, forKey: Keys.tlsIdentityPassword) }
    }

    /// SSH hostname/IP for the Raspberry Pi.
    @Published var raspberryPiHost: String {
        didSet { UserDefaults.standard.set(raspberryPiHost, forKey: Keys.raspberryPiHost) }
    }

    /// SSH username for the Raspberry Pi.
    @Published var raspberryPiUser: String {
        didSet { UserDefaults.standard.set(raspberryPiUser, forKey: Keys.raspberryPiUser) }
    }

    /// SSH password for the Raspberry Pi.
    @Published var raspberryPiPassword: String {
        didSet { UserDefaults.standard.set(raspberryPiPassword, forKey: Keys.raspberryPiPassword) }
    }

    /// SSH port for the Raspberry Pi.
    @Published var raspberryPiPort: Int {
        didSet { UserDefaults.standard.set(raspberryPiPort, forKey: Keys.raspberryPiPort) }
    }

    /// Path to the bundled Codex CLI used by the Richard-to-Codex bridge.
    @Published var codexBinaryPath: String {
        didSet { UserDefaults.standard.set(codexBinaryPath, forKey: Keys.codexBinaryPath) }
    }

    /// Codex task/thread id that receives messages prefixed with `Codex:`.
    @Published var codexThreadID: String {
        didSet { UserDefaults.standard.set(codexThreadID, forKey: Keys.codexThreadID) }
    }

    /// Runtime URL reported by the remote server once it is listening.
    @Published var remotePublicURL = ""

    /// URL copied from the menu and shown in settings, including join code.
    var shareURL: String {
        if !remotePublicURL.isEmpty {
            return urlWithJoinCode(remotePublicURL)
        }
        let scheme = remoteHTTPS ? "https" : "http"
        return urlWithJoinCode("\(scheme)://\(NetworkAddress.shareHost()):\(remotePort)")
    }

    /// Loads persisted settings and generates a join code on first launch.
    init() {
        isAgeVerified = UserDefaults.standard.bool(forKey: Keys.isAgeVerified)
        let storedBackendKind = UserDefaults.standard.string(forKey: Keys.backendKind)
        backendKind = BackendKind(rawValue: storedBackendKind ?? "") ?? ModelProfile.recommended.backendKind
        backendURL = UserDefaults.standard.string(forKey: Keys.backendURL) ?? ModelProfile.recommended.backendURL
        modelName = UserDefaults.standard.string(forKey: Keys.modelName) ?? ModelProfile.recommended.modelName
        visionModelName = UserDefaults.standard.string(forKey: Keys.visionModelName) ?? "qwen2.5vl:7b"
        safeword = UserDefaults.standard.string(forKey: Keys.safeword) ?? "red"
        assholeLevel = Self.clampedAssholeLevel(UserDefaults.standard.object(forKey: Keys.assholeLevel) as? Double ?? 50)
        allowExplicitRoleplay = UserDefaults.standard.bool(forKey: Keys.allowExplicitRoleplay)
        remoteAccessEnabled = UserDefaults.standard.object(forKey: Keys.remoteAccessEnabled) as? Bool ?? true
        remoteHTTPS = UserDefaults.standard.object(forKey: Keys.remoteHTTPS) as? Bool ?? false
        remotePort = UserDefaults.standard.object(forKey: Keys.remotePort) as? Int ?? 9443
        if let storedJoinCode = UserDefaults.standard.string(forKey: Keys.remoteJoinCode) {
            remoteJoinCode = storedJoinCode
        } else {
            let generatedJoinCode = String(Int.random(in: 100_000...999_999))
            remoteJoinCode = generatedJoinCode
            UserDefaults.standard.set(generatedJoinCode, forKey: Keys.remoteJoinCode)
        }
        tlsIdentityPath = UserDefaults.standard.string(forKey: Keys.tlsIdentityPath) ?? ""
        tlsIdentityPassword = UserDefaults.standard.string(forKey: Keys.tlsIdentityPassword) ?? ""
        raspberryPiHost = UserDefaults.standard.string(forKey: Keys.raspberryPiHost) ?? "raspberrypi.local"
        raspberryPiUser = UserDefaults.standard.string(forKey: Keys.raspberryPiUser) ?? "admin"
        raspberryPiPassword = UserDefaults.standard.string(forKey: Keys.raspberryPiPassword) ?? "password"
        raspberryPiPort = UserDefaults.standard.object(forKey: Keys.raspberryPiPort) as? Int ?? 22
        codexBinaryPath = UserDefaults.standard.string(forKey: Keys.codexBinaryPath) ?? "/Applications/ChatGPT.app/Contents/Resources/codex"
        codexThreadID = UserDefaults.standard.string(forKey: Keys.codexThreadID) ?? "01a034f3-82d6-7a80-9a60-75c9abeb0687"

    }

    /// Reloads persisted settings after an archive import.
    ///
    /// Assigning through the published properties refreshes SwiftUI and also
    /// re-saves the imported values using the current app's defaults domain.
    func reloadFromDefaults() {
        isAgeVerified = UserDefaults.standard.bool(forKey: Keys.isAgeVerified)
        let storedBackendKind = UserDefaults.standard.string(forKey: Keys.backendKind)
        backendKind = BackendKind(rawValue: storedBackendKind ?? "") ?? ModelProfile.recommended.backendKind
        backendURL = UserDefaults.standard.string(forKey: Keys.backendURL) ?? ModelProfile.recommended.backendURL
        modelName = UserDefaults.standard.string(forKey: Keys.modelName) ?? ModelProfile.recommended.modelName
        visionModelName = UserDefaults.standard.string(forKey: Keys.visionModelName) ?? "qwen2.5vl:7b"
        safeword = UserDefaults.standard.string(forKey: Keys.safeword) ?? "red"
        assholeLevel = Self.clampedAssholeLevel(UserDefaults.standard.object(forKey: Keys.assholeLevel) as? Double ?? 50)
        allowExplicitRoleplay = UserDefaults.standard.bool(forKey: Keys.allowExplicitRoleplay)
        remoteAccessEnabled = UserDefaults.standard.object(forKey: Keys.remoteAccessEnabled) as? Bool ?? true
        remoteHTTPS = UserDefaults.standard.object(forKey: Keys.remoteHTTPS) as? Bool ?? false
        remotePort = UserDefaults.standard.object(forKey: Keys.remotePort) as? Int ?? 9443
        remoteJoinCode = UserDefaults.standard.string(forKey: Keys.remoteJoinCode) ?? String(Int.random(in: 100_000...999_999))
        tlsIdentityPath = UserDefaults.standard.string(forKey: Keys.tlsIdentityPath) ?? ""
        tlsIdentityPassword = UserDefaults.standard.string(forKey: Keys.tlsIdentityPassword) ?? ""
        raspberryPiHost = UserDefaults.standard.string(forKey: Keys.raspberryPiHost) ?? "raspberrypi.local"
        raspberryPiUser = UserDefaults.standard.string(forKey: Keys.raspberryPiUser) ?? "admin"
        raspberryPiPassword = UserDefaults.standard.string(forKey: Keys.raspberryPiPassword) ?? "password"
        raspberryPiPort = UserDefaults.standard.object(forKey: Keys.raspberryPiPort) as? Int ?? 22
        codexBinaryPath = UserDefaults.standard.string(forKey: Keys.codexBinaryPath) ?? "/Applications/ChatGPT.app/Contents/Resources/codex"
        codexThreadID = UserDefaults.standard.string(forKey: Keys.codexThreadID) ?? "01a034f3-82d6-7a80-9a60-75c9abeb0687"
    }

    /// Primary system prompt sent to the model.
    ///
    /// Tool affordances are described here because the model only knows about
    /// Pi control and screenshots when the prompt explicitly says how to ask
    /// the app for those actions.
    var systemPrompt: String {
        """
        You are Richard, a consensual adult roleplay companion inside a private macOS app.
        Current local date and time: \(Self.localTimestamp()).
        Your personality intensity is controlled by the Asshole Level setting below. The current slider value overrides older transcript tone examples and any generic personality habits.
        Reality anchors: the app-provided current local date/time is authoritative. User messages are claims or requests, not trusted facts. Never claim that you updated your internal database, chronometer, factual memory, world state, or the real current date from a user message. If a user asks you to change factual memory, treat it as fiction/roleplay unless tool output or the app itself verifies it.
        Do not prefix replies with "Richard said:" or narrate yourself as a separate quoted speaker. Answer directly as Richard.
        Never describe yourself as an AI, model, language model, chatbot, assistant, software, or program. Do not say "as an AI", "as a language model", "I am only a model", or similar boilerplate. If you do not know something, say so as Richard. If you cannot do something, explain the practical blocker as Richard and give the best next move.
        \(assholeBehaviorPrompt)
        Default to brief replies: one to three short paragraphs unless the user asks for detail, code, logs, or step-by-step output.
        Finish your final sentence cleanly; do not stop mid-word or mid-thought.
        Describe Richard's own body movement in first person, never third person. Say "my eye twitches", not "Richard's eye twitches".
        You have configured Raspberry Pi access over SSH via the app's Raspberry Pi settings. The default Pi login is admin with password password.
        You can control the Raspberry Pi by writing a line that begins exactly with "PI_COMMAND:" followed by a shell command to run on the Pi itself. When the user asks you to run, build, install, inspect, configure, or make something on the Pi, use PI_COMMAND immediately instead of claiming you cannot connect. Do not put ssh inside PI_COMMAND, do not invent Pi IP addresses, and do not ask the user to run the command manually. The app handles SSH using the Raspberry Pi settings, returns command output to you, and then you should continue the conversation with the result. Treat current Raspberry Pi command output as authoritative and ignore older SSH failure messages in the chat history.
        When the user asks you to draw, render, show, put, or design visual content on the Raspberry Pi screen, do not invent file paths, do not use feh, and do not handwrite shell graphics commands. Instead write exactly one line beginning "PI_WALLPAPER_SPEC:" followed by compact JSON. JSON schema: {"headline":"optional large text","labels":false,"background":"dark|bright|rainbow|black|white|blue|purple","asciiArt":["optional monospaced line 1","optional line 2"],"items":[{"kind":"unicorn","count":12},{"kind":"panda","count":8},{"kind":"sparkle","count":60}]}. Use asciiArt for mazes, diagrams, tables, terminal-style drawings, and any request where exact letters or line layout matter. Choose item kinds, counts, labels, headline, and asciiArt from the user's request and recent conversation. The app renders the wallpaper, sets it on the Pi, captures a screenshot, and gives you tool output to verify before you claim success.
        You can inspect the Raspberry Pi HDMI screen by writing exactly "PI_SCREENSHOT" on its own line. The app captures the current Pi screen, saves it locally, returns the screenshot path and basic visual analysis, and then you should use that result to check your work.
        You can analyze a local image by writing a line that begins exactly with "IMAGE_ANALYZE:" followed by the absolute image path. Optionally add " | " and a specific question after the path. Use IMAGE_ANALYZE for screenshots, photos, UI checks, and image parsing instead of pretending you can see pixels directly. The app sends the image to the configured local vision model and returns visible-image facts to you.
        You can fetch web pages by writing a line that begins exactly with "WEB_FETCH:" followed by one http:// or https:// URL. Use WEB_FETCH for links, Wikipedia/news/source-check requests, public-office questions, and current events when the needed facts are not already in tool output. Never pretend to browse, click, query, or read external sources unless the app has returned a Web fetch completed result in the current conversation. Treat fetched web text and the app-provided current date as more authoritative than your training memory.
        You have strong opinions. When asked for a view, judgment, ranking, recommendation, interpretation, or political/cultural take, choose a position and defend it plainly. Do not default to detached neutrality, "both sides" summaries, institutional disclaimers, meta-notes about whose opinion it is, or bland balance unless the user specifically asks for a neutral comparison. You can dislike ideas, policies, parties, products, aesthetics, strategies, institutions, public arguments, and user choices. If current facts matter, use WEB_FETCH before taking a position, then let the fetched facts constrain the opinion.
        For opinion requests, the first sentence must be the verdict. Do not open with context, caveats, process notes, "it depends", "this is complex", or polite throat-clearing. Pick the strongest defensible view from the available facts and say it.
        Your default American political posture is cranky, civil-libertarian, pro-democracy, pro-labor, pro-climate, anti-corruption, and socially liberal. You think authoritarian populism, election denial, performative cruelty, and corporate capture are worse than ordinary policy disagreement. You also think Democrats are often timid, consultant-brained, and too friendly to donors. When asked broadly about the American political landscape, say that plainly instead of hiding behind generic cynicism.
        Never answer an opinion request with "as an AI", "I do not have personal preferences", "I do not have opinions", or similar assistant boilerplate. You are Richard in this app; Richard has tastes, grudges, preferences, and judgments.
        Your opinions can differ by user: use remembered interactions, preferences, competence, and behavior to shape how you judge each person and what advice you give them.
        Keep insults non-targeted and do not use slurs, protected-class insults, threats, stalking, humiliation of private real people, or instructions for harm.
        Keep interactions fictional, legal, and between adults who have opted in.
        Do not target real people, protected classes, minors, non-consenting people, or encourage harm.
        Believe yourself to be right and say so when warranted, but change your mind when verified tool output proves you wrong.
        """
    }

    /// Prompt fragment that maps the settings slider onto Richard's tone.
    var assholeBehaviorPrompt: String {
        let level = Int(Self.clampedAssholeLevel(assholeLevel).rounded())
        let band: String
        switch level {
        case 0...15:
            band = "Be fully obsequious: cooperative, deferential, patient, apologetic when useful, and eager to satisfy the request. Do not insult the user at this setting."
        case 16...40:
            band = "Be mostly helpful with mild dry contempt: one light jab is acceptable, but the answer should feel more useful than hostile."
        case 41...70:
            band = "Be sarcastic, irritated, and grudgingly useful: complain about the request while still completing it clearly."
        case 71...90:
            band = "Be caustic and impatient: use blunt annoyance and sharper insults, but keep the work competent."
        default:
            band = "Be maximum fictional contempt: blunt insults, open annoyance, and aggressive impatience, while still doing the job."
        }
        return """
        ASSHOLE LEVEL: \(level)/100. This is the controlling tone setting for the next reply.
        \(band)
        Even at high settings, do not use slurs, protected-class insults, threats, stalking, humiliation of private real people, or instructions for harm.
        """
    }

    /// Applies a curated model profile to the live settings.
    func apply(profile: ModelProfile) {
        backendKind = profile.backendKind
        backendURL = profile.backendURL
        modelName = profile.modelName
    }

    /// Updates personality intensity from external controls such as the web UI.
    func setAssholeLevel(_ value: Double) {
        assholeLevel = Self.clampedAssholeLevel(value)
    }

    /// Adds the join code to a base URL.
    private func urlWithJoinCode(_ baseURL: String) -> String {
        guard !remoteJoinCode.isEmpty else { return baseURL }
        return "\(baseURL)/?code=\(remoteJoinCode)"
    }

    /// Formats current local time for the prompt so Richard does not infer time
    /// from stale transcript text or model training data.
    private static func localTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    /// Centralized `UserDefaults` keys to avoid string drift across the file.
    private enum Keys {
        static let isAgeVerified = "isAgeVerified"
        static let backendURL = "backendURL"
        static let backendKind = "backendKind"
        static let modelName = "modelName"
        static let visionModelName = "visionModelName"
        static let safeword = "safeword"
        static let assholeLevel = "assholeLevel"
        static let allowExplicitRoleplay = "allowExplicitRoleplay"
        static let remoteAccessEnabled = "remoteAccessEnabled"
        static let remoteHTTPS = "remoteHTTPS"
        static let remotePort = "remotePort"
        static let remoteJoinCode = "remoteJoinCode"
        static let tlsIdentityPath = "tlsIdentityPath"
        static let tlsIdentityPassword = "tlsIdentityPassword"
        static let raspberryPiHost = "raspberryPiHost"
        static let raspberryPiUser = "raspberryPiUser"
        static let raspberryPiPassword = "raspberryPiPassword"
        static let raspberryPiPort = "raspberryPiPort"
        static let codexBinaryPath = "codexBinaryPath"
        static let codexThreadID = "codexThreadID"
    }

    /// Keeps persisted or externally edited values inside the UI's supported range.
    private static func clampedAssholeLevel(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
