import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AudioPluginManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PluginStore()

    var body: some Scene {
        WindowGroup("音频插件管理器") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1120, height: 680)
        .windowResizability(.contentMinSize)
    }
}
