# Richard

Richard is a native SwiftUI macOS chat runtime for a local Ollama-compatible model. The core app runs on one Mac, stores a single shared conversation locally, and can expose that same chat over the local office network through a built-in HTTP server.

The project is built for private, consensual adult fictional roleplay. The shipped prompt gives Richard a sarcastic, grudgingly helpful persona while keeping the runtime useful: local chat, remote browser chat, image paste/analysis, optional Codex handoff, and optional Raspberry Pi control.

## Core Features

- Native macOS SwiftUI chat app.
- Local model backend through Ollama or an OpenAI-compatible local server.
- One shared transcript across the Mac app and remote browser clients.
- Local-network HTTP sharing with a join code.
- Required remote name prompt so multi-user messages are attributed.
- Per-user relationship memory persisted locally.
- Paste or attach images in the Mac app and the web chat.
- Optional local vision model for image analysis.
- Optional `Codex:` bridge for sending development notes from Richard into a Codex task.
- Optional Raspberry Pi SSH control and screen verification.

## Requirements

- macOS 14 or newer.
- Xcode installed at `/Applications/Xcode.app`.
- Xcode command-line tools pointed at Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

- A local model server. Ollama is the default path. If `brew` is not installed yet, follow the official [Homebrew installation instructions](https://docs.brew.sh/Installation) first:

```sh
brew install ollama
ollama serve
```

The app can run without the optional Pi, vision, or Codex features. Those are configured in settings after launch.

## Recommended Model

The default chat model profile is:

```txt
hf.co/TheDrummer/Cydonia-24B-v4.3-GGUF:Q4_K_M
```

Pull it with Ollama:

```sh
ollama pull hf.co/TheDrummer/Cydonia-24B-v4.3-GGUF:Q4_K_M
```

The app defaults to:

```txt
Backend URL: http://localhost:11434
Model:       hf.co/TheDrummer/Cydonia-24B-v4.3-GGUF:Q4_K_M
```

For a smaller/faster fallback, use the Stheno model profile in app settings.

## Build And Run

Open the Xcode project directly:

```sh
open Richard.xcodeproj
```

Select the `Richard` scheme and run it on `My Mac`.

To build and copy a runnable `.app` bundle:

```sh
./scripts/package_app.sh
open build/Richard.app
```

`Package.swift` exists so the source can also be inspected as a Swift package, but the Xcode project is the preferred app target because it supplies a proper bundle identifier, app icon, asset catalog, and Info.plist.

## First Launch Setup

On launch, Richard creates setup helpers in:

```txt
~/Library/Application Support/Richard/Setup
```

The host window shows a `Setup Checks` panel on every restart. It verifies that
the generated setup/check scripts exist, required runtime directories exist,
Homebrew is available, Ollama is installed, the Ollama server is reachable, and
the configured chat model is present. Optional checks also report the vision
model and Codex CLI path.

Generated helper scripts:

- `setup-richard.command`: installs Ollama through Homebrew if needed, starts
  Ollama, pulls the configured chat and vision models, and creates Richard's
  runtime folders.
- `check-richard.command`: performs a read-only runtime check from Terminal.

The setup script still expects Homebrew to be installed first. If `brew` is not
installed yet, follow the official [Homebrew installation instructions](https://docs.brew.sh/Installation).

Open Richard preferences and check:

- Backend kind: usually `Ollama`.
- Backend URL: usually `http://localhost:11434`.
- Model name: the Ollama model tag to use.
- Vision model: optional, used only for image parsing.
- Behavior: set the Asshole Level slider from `0` for fully obsequious to `100` for total asshole.
- Remote access: enable only when you want browser clients on the network.
- Join code: required by browser users and JSON API clients.

Settings are stored in the local user's `UserDefaults`, not in the repo. A new computer starts with the defaults from `AppSettings.swift`.

## Local-Network Sharing

Richard serves one shared chat over HTTP when remote access is enabled. Everyone sees and contributes to the same transcript.

Default local URL:

```txt
http://127.0.0.1:9443
```

Office users should use the LAN URL shown in the app's settings or copied from the app menu. They must enter the join code. Their first unskippable prompt asks for a name, and that name is used for message attribution and per-user memory.

Already-open browser clients poll the app every two seconds. If Richard quits, crashes, or stops answering, those clients show a red `Richard is offline` banner and disable sending until the app comes back. Browser users can also open the gear beside the message field and adjust the shared Asshole Level slider; it writes to the same persisted setting as the Mac Preferences control.

Useful endpoints:

```txt
GET  /api/messages?code=JOIN_CODE
GET  /api/activity?code=JOIN_CODE
POST /api/messages
POST /api/codex-reply
POST /api/settings
```

Post a chat message:

```sh
curl -s http://127.0.0.1:9443/api/messages \
  -H 'Content-Type: application/json' \
  -H 'X-Richard-Code: JOIN_CODE' \
  -d '{"author":"Alex","content":"hello","code":"JOIN_CODE"}'
```

## Import And Export

The headless host panel includes `Export` and `Import` buttons under `History Archive`.

Export writes a `.richardarchive` zip package containing:

- `defaults.plist`, a snapshot of Richard's `com.local.richard` defaults domain.
- `ApplicationSupport-Richard`, including uploaded image attachments, Pi screenshots, generated setup scripts, and Codex bridge working files.

Import restores that archive into the current user account, reloads app settings, reloads the shared transcript, restarts the local web listener with the imported settings, and reruns setup checks.

Machine-specific dependencies are still external: install Homebrew/Ollama and pull the configured models on the destination Mac. The host panel's generated setup script handles that after Homebrew is present.

## HTTPS

The built-in server can use HTTPS if you provide a PKCS#12 identity in settings.

Create a local self-signed certificate:

```sh
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout richard.key -out richard.crt -days 365 \
  -subj "/CN=richard.local"

openssl pkcs12 -export \
  -out richard.p12 \
  -inkey richard.key \
  -in richard.crt
```

Put the absolute `.p12` path and password in Richard settings. Browsers on other machines will need to trust the certificate. For a real office deployment, a trusted reverse proxy can terminate HTTPS while Richard serves plain HTTP internally.

Do not commit generated certificate files. `.gitignore` excludes common key and certificate extensions.

## Images And Vision

Images can be pasted or attached in both the native app and the web chat. Richard stores uploaded image files under the local Application Support directory and adds image directives to the prompt.

For image parsing, install a local Ollama vision model and set it in Richard settings. A practical default is:

```sh
ollama pull llava:latest
```

Image analysis currently expects the Ollama backend.

## Codex Bridge

Messages beginning with:

```txt
Codex:
```

are passed to the configured Codex task instead of the chat model. Codex replies can be posted back into Richard through `/api/codex-reply`.

Settings:

- Codex CLI path, default: `/Applications/ChatGPT.app/Contents/Resources/codex`
- Codex thread ID
- Richard join code

The bridge launches the Codex CLI from:

```txt
~/Library/Application Support/Richard/CodexBridge
```

That avoids macOS Documents-folder permission prompts while still instructing Codex to work in this repo.

## Raspberry Pi Integration

Pi control is optional and ancillary. Richard can run commands over SSH using the Pi settings:

```txt
Host:     raspberrypi.local
User:     admin
Password: password
Port:     22
```

The defaults are intentionally visible in settings so a different machine can update them without touching source.

Richard supports three Pi tool patterns through the model prompt:

- `PI_COMMAND:` runs a shell command on the Pi over SSH.
- `PI_SCREENSHOT` captures the Pi HDMI screen for verification.
- `PI_WALLPAPER_SPEC:` lets Richard describe visual content as JSON, then the app renders and sets a wallpaper on the Pi. The spec supports repeated visual items plus optional `asciiArt` lines for mazes, diagrams, tables, and other layout-sensitive text.

Pi visual requests are deliberately routed through a generic wallpaper spec. The app should not grow request-specific drawing catches for individual prompts.

## Diagnostics

Check recent runtime activity:

```sh
./scripts/richard-status.sh JOIN_CODE
```

Or directly:

```sh
curl -s 'http://127.0.0.1:9443/api/activity?code=JOIN_CODE'
```

The activity feed is intentionally summarized. It is for debugging progress and failures, not for replaying the full transcript.

## Portability Notes

When moving to another Mac:

1. Install Xcode and point `xcode-select` at it.
2. Install Ollama and pull the chosen chat model.
3. Clone this repo.
4. Build with `./scripts/package_app.sh` or run from Xcode.
5. Open settings and confirm backend URL, model name, join code, Codex path/thread, and Pi credentials.
6. Enable remote access only after confirming the local app works.

Local transcripts, per-user memory, uploaded images, screenshots, certificates, and settings are not stored in git. They live in the user's local Library/Application Support and UserDefaults.

## Development

Keep implementation comments focused on behavior that is not obvious from the code. Shared runtime paths should stay documented because Richard combines native UI, local model calls, browser APIs, Codex handoff, and Pi tools in one process.

Before committing:

```sh
./scripts/package_app.sh
```

Then check source state:

```sh
git status --short
```
