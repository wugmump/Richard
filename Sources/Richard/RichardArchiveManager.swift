import Foundation

/// Exports and imports portable Richard history archives.
///
/// A `.richardarchive` is a zip file containing the app's persisted defaults
/// plus the Richard Application Support directory. It is meant for migrating
/// transcript, per-user memory, uploaded images, screenshots, and local
/// preferences to another Mac running the same app.
enum RichardArchiveManager {
    /// Name of the property-list snapshot inside an archive.
    private static let defaultsFileName = "defaults.plist"
    /// Name of the Application Support copy inside an archive.
    private static let supportDirectoryName = "ApplicationSupport-Richard"
    /// Bundle id used by the current Xcode project.
    private static let defaultsDomain = "com.local.richard"

    /// Creates a `.richardarchive` at the selected destination.
    static func exportArchive(to destinationURL: URL) throws {
        let stagingRoot = try temporaryDirectory(named: "RichardExport")
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let archiveRoot = stagingRoot.appending(path: "RichardArchive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try writeDefaultsSnapshot(to: archiveRoot.appending(path: defaultsFileName))
        try copyApplicationSupport(to: archiveRoot.appending(path: supportDirectoryName, directoryHint: .isDirectory))

        try? FileManager.default.removeItem(at: destinationURL)
        try run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", archiveRoot.path, destinationURL.path])
    }

    /// Restores a `.richardarchive` into the current user's Richard storage.
    static func importArchive(from sourceURL: URL) throws {
        let stagingRoot = try temporaryDirectory(named: "RichardImport")
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        try run("/usr/bin/ditto", arguments: ["-x", "-k", sourceURL.path, stagingRoot.path])
        let archiveRoot = stagingRoot.appending(path: "RichardArchive", directoryHint: .isDirectory)
        let defaultsURL = archiveRoot.appending(path: defaultsFileName)
        let supportURL = archiveRoot.appending(path: supportDirectoryName, directoryHint: .isDirectory)

        try restoreDefaults(from: defaultsURL)
        try restoreApplicationSupport(from: supportURL)
        UserDefaults.standard.synchronize()
    }

    /// Writes the current defaults domain as a binary property list.
    private static func writeDefaultsSnapshot(to url: URL) throws {
        let domain = UserDefaults.standard.persistentDomain(forName: defaultsDomain) ?? [:]
        let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Restores defaults without relying on the external `defaults` command.
    private static func restoreDefaults(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let domain = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw RichardArchiveError.invalidDefaultsSnapshot
        }
        UserDefaults.standard.setPersistentDomain(domain, forName: defaultsDomain)
    }

    /// Copies Richard's Application Support data into the archive.
    private static func copyApplicationSupport(to destinationURL: URL) throws {
        let sourceURL = richardApplicationSupportURL()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            return
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    /// Restores Richard's Application Support data from an archive.
    private static func restoreApplicationSupport(from sourceURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let destinationURL = richardApplicationSupportURL()
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    /// Current user's Richard Application Support directory.
    private static func richardApplicationSupportURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return appSupport.appending(path: "Richard", directoryHint: .isDirectory)
    }

    /// Unique temporary directory for staging import/export contents.
    private static func temporaryDirectory(named prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "\(prefix)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs a small system tool and throws its stderr on failure.
    private static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RichardArchiveError.processFailed(message?.isEmpty == false ? message! : "Archive command failed.")
        }
    }
}

/// Errors surfaced by archive import/export buttons.
private enum RichardArchiveError: LocalizedError {
    case invalidDefaultsSnapshot
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDefaultsSnapshot:
            "Archive defaults snapshot is not readable."
        case .processFailed(let message):
            message
        }
    }
}
