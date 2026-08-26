import AppKit
import SwiftUI

/// Main macOS application entry point.
@main
struct RichardApp: App {
    /// Shared app settings object injected into the window and settings scene.
    @StateObject private var settings = AppSettings()

    /// Declares the main chat window, settings window, and custom commands.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 520)
        }

        .commands {
            // The share URL is computed live from remote access settings so the
            // menu item stays useful when ports, HTTPS, or public URLs change.
            CommandMenu("Richard") {
                Button("Copy Public URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(settings.shareURL, forType: .string)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
    }
}
