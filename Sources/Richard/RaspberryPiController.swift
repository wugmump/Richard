import Foundation
import AppKit
import Darwin

/// Result of a command executed on the Raspberry Pi over SSH.
struct RaspberryPiCommandResult: Equatable {
    /// Remote process exit code, or `-1` for local launch/decoding failures.
    let exitCode: Int32
    /// Combined stdout/stderr after wrapper noise has been removed.
    let output: String
}

/// Result of capturing the Raspberry Pi's current HDMI/Wayland screen.
struct RaspberryPiScreenshotResult: Equatable {
    /// Exit code from the capture pipeline.
    let exitCode: Int32
    /// Human-readable capture output or error text.
    let output: String
    /// Local path to the saved screenshot when capture succeeds.
    let localPath: String?
    /// Lightweight pixel-analysis summary for text-only model context.
    let analysis: String?
}

/// Thread-safe holder used by background pipe readers.
///
/// `Process` can deadlock if a child emits enough data to fill stdout/stderr
/// while the parent waits for exit. The command runner drains pipes concurrently
/// and stores the data here.
private final class PipeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    /// Locked access to the accumulated pipe data.
    var data: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedData
        }
        set {
            lock.lock()
            storedData = newValue
            lock.unlock()
        }
    }
}

/// Sidebar controller for manually running Raspberry Pi commands.
@MainActor
final class RaspberryPiController: ObservableObject {
    /// Command typed into the sidebar field.
    @Published var command = "uname -a"
    /// Last command output shown in the sidebar.
    @Published var output = "No Raspberry Pi command has been run yet."
    /// Prevents duplicate sidebar command submissions.
    @Published var isRunning = false

    /// Runs the current sidebar command against the configured Pi.
    func run(settings: AppSettings) {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty, !isRunning else { return }

        let host = settings.raspberryPiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = settings.raspberryPiUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = settings.raspberryPiPassword
        let port = settings.raspberryPiPort

        guard !host.isEmpty, !user.isEmpty else {
            output = "Raspberry Pi host and user are required."
            return
        }

        isRunning = true
        output = "Running on \(user)@\(host):\(port)..."

        Task {
            let result = await RaspberryPiCommandRunner.run(
                host: host,
                user: user,
                password: password,
                port: port,
                command: trimmedCommand
            )

            output = result.output
            isRunning = false
        }
    }
}

/// Low-level Raspberry Pi SSH and screen-capture utilities.
enum RaspberryPiCommandRunner {
    /// Captures the Wayland screen with `grim`, downsizes it on the Pi to avoid
    /// huge SSH transfers, then prints base64 for the Mac app to decode.
    private static let screenshotCommand = "rm -f /tmp/richard-screen.png /tmp/richard-screen-small.png; timeout 8s env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 grim /tmp/richard-screen.png && python3 -c \"from PIL import Image; im=Image.open('/tmp/richard-screen.png'); im.thumbnail((1280,720)); im.save('/tmp/richard-screen-small.png')\" && base64 -w0 /tmp/richard-screen-small.png"

    /// Executes one shell command on the Pi.
    ///
    /// Password-based auth uses `/usr/bin/expect` because macOS `ssh` will not
    /// read passwords from stdin. Key-based auth can use plain `ssh`.
    static func run(host: String, user: String, password: String, port: Int, command: String) async -> RaspberryPiCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = password.isEmpty
                    ? Self.sshProcess(host: host, user: user, port: port, command: command)
                    : Self.expectSSHProcess(host: host, user: user, password: password, port: port, command: command)

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    // Drain stdout and stderr while the process runs. This is
                    // required for large outputs like screenshot base64.
                    let readGroup = DispatchGroup()
                    let outData = PipeDataBox()
                    let errData = PipeDataBox()

                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outData.data = stdout.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errData.data = stderr.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    // The remote `timeout` command handles known long-running
                    // Pi tasks, but a local SSH/Expect process can still wedge.
                    let watchdog = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                            Thread.sleep(forTimeInterval: 1)
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: watchdog)
                    process.waitUntilExit()
                    watchdog.cancel()
                    readGroup.wait()

                    let out = String(data: outData.data, encoding: .utf8) ?? ""
                    let err = String(data: errData.data, encoding: .utf8) ?? ""
                    // SSH, Expect, stdout, and stderr are merged because the UI
                    // needs a single readable command result.
                    let combined = [out, err]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    let cleaned = Self.cleanedSSHOutput(combined)

                    continuation.resume(returning: RaspberryPiCommandResult(
                        exitCode: process.terminationStatus,
                        output: cleaned.isEmpty ? "Command exited \(process.terminationStatus) with no output." : cleaned
                    ))
                } catch {
                    continuation.resume(returning: RaspberryPiCommandResult(
                        exitCode: -1,
                        output: error.localizedDescription
                    ))
                }
            }
        }
    }

    /// Captures the Pi screen and saves the decoded PNG locally.
    static func captureScreenshot(host: String, user: String, password: String, port: Int) async -> RaspberryPiScreenshotResult {
        let result = await run(host: host, user: user, password: password, port: port, command: screenshotCommand)
        // Base64 may include line wrapping or whitespace, so strip everything
        // that is not part of the encoded payload before decoding.
        let compactBase64 = result.output
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let data = Data(base64Encoded: compactBase64), !data.isEmpty else {
            guard result.exitCode == 0 else {
                return RaspberryPiScreenshotResult(exitCode: result.exitCode, output: result.output, localPath: nil, analysis: nil)
            }

            return RaspberryPiScreenshotResult(
                exitCode: -1,
                output: "Screenshot command returned data that was not valid base64.",
                localPath: nil,
                analysis: nil
            )
        }

        do {
            let url = try screenshotURL()
            try data.write(to: url, options: .atomic)
            let analysis = analyzeScreenshot(data: data)
            return RaspberryPiScreenshotResult(
                exitCode: 0,
                output: "Saved Pi screenshot to \(url.path)",
                localPath: url.path,
                analysis: analysis
            )
        } catch {
            return RaspberryPiScreenshotResult(exitCode: -1, output: error.localizedDescription, localPath: nil, analysis: nil)
        }
    }

    /// Creates a timestamped local screenshot path.
    private static func screenshotURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let directory = appSupport.appending(path: "Richard/Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "pi-screen-\(timestamp).png")
    }

    /// Performs cheap image analysis for text-only verification.
    ///
    /// This is not computer vision; it is a pragmatic signal for whether the
    /// display appears colorful/rainbow-like and whether the image is mostly
    /// dark or blank.
    private static func analyzeScreenshot(data: Data) -> String {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Screenshot saved, but the app could not decode it for analysis."
        }

        let width = cgImage.width
        let height = cgImage.height
        let sampleWidth = min(width, 160)
        let sampleHeight = min(height, 90)
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return "Screenshot saved at \(width)x\(height), but pixel analysis failed."
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        // Sample the downscaled pixels to compute brightness, saturation, and
        // broad hue coverage.
        var brightCount = 0
        var darkCount = 0
        var saturatedCount = 0
        var hueBuckets = Set<Int>()
        var totalR = 0
        var totalG = 0
        var totalB = 0
        let pixelCount = sampleWidth * sampleHeight

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            totalR += r
            totalG += g
            totalB += b

            let maxChannel = max(r, g, b)
            let minChannel = min(r, g, b)
            let brightness = (r + g + b) / 3
            if brightness > 210 { brightCount += 1 }
            if brightness < 45 { darkCount += 1 }

            let saturation = maxChannel - minChannel
            if saturation > 80 {
                saturatedCount += 1
                hueBuckets.insert(hueBucket(red: r, green: g, blue: b))
            }
        }

        let averageR = totalR / max(pixelCount, 1)
        let averageG = totalG / max(pixelCount, 1)
        let averageB = totalB / max(pixelCount, 1)
        let brightPercent = brightCount * 100 / max(pixelCount, 1)
        let darkPercent = darkCount * 100 / max(pixelCount, 1)
        let saturatedPercent = saturatedCount * 100 / max(pixelCount, 1)
        let rainbowLikely = saturatedPercent > 35 && hueBuckets.count >= 5

        return """
        Screenshot \(width)x\(height). Average RGB \(averageR), \(averageG), \(averageB). Bright pixels \(brightPercent)%, dark pixels \(darkPercent)%, saturated pixels \(saturatedPercent)%, hue spread \(hueBuckets.count)/12. Rainbow-like color spread: \(rainbowLikely ? "yes" : "no").
        """
    }

    /// Maps an RGB color into one of twelve hue buckets.
    private static func hueBucket(red: Int, green: Int, blue: Int) -> Int {
        let r = Double(red) / 255.0
        let g = Double(green) / 255.0
        let b = Double(blue) / 255.0
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        guard delta > 0 else { return 0 }

        let hue: Double
        if maxValue == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == g {
            hue = 60 * (((b - r) / delta) + 2)
        } else {
            hue = 60 * (((r - g) / delta) + 4)
        }

        let normalizedHue = hue < 0 ? hue + 360 : hue
        return min(11, max(0, Int(normalizedHue / 30)))
    }

    /// Builds a plain SSH process for key-based auth/no-password mode.
    private static func sshProcess(host: String, user: String, port: Int, command: String) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(port)",
            "\(user)@\(host)",
            command
        ]
        return process
    }

    /// Builds an Expect-wrapped SSH process for password auth.
    ///
    /// Command parameters are passed through environment variables to avoid the
    /// earlier bug where Expect interpreted positional arguments as files to
    /// `source`.
    private static func expectSSHProcess(host: String, user: String, password: String, port: Int, command: String) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/expect")
        process.environment = ProcessInfo.processInfo.environment.merging([
            "RICHARD_PI_HOST": host,
            "RICHARD_PI_USER": user,
            "RICHARD_PI_PASSWORD": password,
            "RICHARD_PI_PORT": "\(port)",
            "RICHARD_PI_COMMAND": command
        ]) { _, new in new }
        process.arguments = [
            "-c",
            """
            set timeout 30
            set host $env(RICHARD_PI_HOST)
            set user $env(RICHARD_PI_USER)
            set port $env(RICHARD_PI_PORT)
            set remoteCommand $env(RICHARD_PI_COMMAND)
            set password $env(RICHARD_PI_PASSWORD)
            spawn /usr/bin/ssh -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o StrictHostKeyChecking=accept-new -p $port -- "$user@$host" "$remoteCommand"
            expect {
                -re "(?i)password:" {
                    send -- "$password\\r"
                    expect eof
                }
                eof {}
                timeout {
                    exit 124
                }
            }
            catch wait result
            exit [lindex $result 3]
            """
        ]
        return process
    }

    /// Removes Expect wrapper chatter from command output.
    private static func cleanedSSHOutput(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return true }
                guard !trimmed.hasPrefix("spawn /usr/bin/ssh") else { return false }
                guard !trimmed.localizedCaseInsensitiveContains("password:") else { return false }
                return true
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
