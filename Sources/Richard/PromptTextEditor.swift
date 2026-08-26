import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSTextView` for the chat composer.
///
/// SwiftUI's standard multiline text input does not give precise enough control
/// over Return vs. Shift-Return on macOS. This representable keeps native text
/// editing while allowing Return to submit and Shift-Return to insert a newline.
struct PromptTextEditor: NSViewRepresentable {
    /// Bound composer text.
    @Binding var text: String
    /// Called when the user presses Return without Shift.
    var onSubmit: () -> Void
    /// Called with saved image paths when the user pastes image content.
    var onPasteImages: ([String]) -> Void = { _ in }

    /// Creates the scroll view and configured text view used by SwiftUI.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        textView.minSize = NSSize(width: 0, height: 44)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    /// Keeps the AppKit text view synchronized with SwiftUI state.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        if textView.string != text {
            textView.string = text
        }
    }

    /// Creates the delegate bridge that writes AppKit edits back to the binding.
    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// NSTextView delegate used to mirror text changes into SwiftUI.
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        /// Stores the binding rather than a copy of the current value.
        init(text: Binding<String>) {
            _text = text
        }

        /// Propagates user edits into the SwiftUI `@Binding`.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

/// NSTextView subclass that turns Return into submit while preserving
/// Shift-Return as a soft line break.
private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (([String]) -> Void)?

    /// Handles Return/Numpad Return before AppKit inserts a newline.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isShift = event.modifierFlags.contains(.shift)

        if isReturn && !isShift {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }

    /// Converts pasted image data or Finder image files into saved attachments
    /// instead of letting NSTextView ignore or embed rich content.
    override func paste(_ sender: Any?) {
        let paths = Self.savedImagePaths(from: NSPasteboard.general)
        guard !paths.isEmpty else {
            super.paste(sender)
            return
        }

        onPasteImages?(paths)
    }

    /// Reads common image payloads from the pasteboard and stores them locally.
    private static func savedImagePaths(from pasteboard: NSPasteboard) -> [String] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var paths: [String] = []

        for item in items {
            if let fileURLString = item.string(forType: .fileURL),
               let fileURL = URL(string: fileURLString),
               isImageFile(fileURL),
               let path = try? ImageAttachmentStore.save(fileURL: fileURL) {
                paths.append(path)
                continue
            }

            if let data = item.data(forType: .png),
               let path = try? ImageAttachmentStore.save(data: data, suggestedExtension: "png") {
                paths.append(path)
                continue
            }

            if let data = item.data(forType: .tiff),
               let image = NSImage(data: data),
               let path = try? ImageAttachmentStore.save(image: image) {
                paths.append(path)
                continue
            }
        }

        if paths.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            paths = images.compactMap { try? ImageAttachmentStore.save(image: $0) }
        }

        return paths
    }

    /// Restricts Finder file paste handling to common image extensions.
    private static func isImageFile(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "heif"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}
