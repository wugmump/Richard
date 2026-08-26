import AppKit
import Foundation

/// Saves pasted or uploaded images so local vision models can read them from a
/// stable filesystem path.
enum ImageAttachmentStore {
    /// Writes already-encoded image bytes to Application Support and returns
    /// the absolute path.
    static func save(data: Data, suggestedExtension: String = "png") throws -> String {
        let directory = try attachmentDirectory()
        let cleanExtension = sanitizedExtension(suggestedExtension)
        let filename = "pasted-\(timestamp())-\(UUID().uuidString.prefix(8)).\(cleanExtension)"
        let url = directory.appending(path: filename)
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// Encodes an AppKit image as PNG, saves it, and returns the absolute path.
    static func save(image: NSImage) throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return try save(data: pngData, suggestedExtension: "png")
    }

    /// Saves a pasted Finder image file by copying its bytes into the attachment
    /// directory and preserving a usable extension.
    static func save(fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension
        return try save(data: data, suggestedExtension: ext)
    }

    /// Directory used for all chat image attachments.
    private static func attachmentDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let directory = appSupport.appending(path: "Richard/Attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Keeps extensions filesystem-safe and short.
    private static func sanitizedExtension(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = value
            .lowercased()
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
        return cleaned.isEmpty ? "png" : String(cleaned.prefix(8))
    }

    /// Timestamp formatted for filenames.
    private static func timestamp() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }
}
