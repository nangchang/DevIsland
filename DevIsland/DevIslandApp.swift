import SwiftUI

@main
struct DevIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The main notch window will be handled by AppKit (NSPanel) in AppDelegate
        // We can keep Settings as a standard SwiftUI Window
        Settings {
            Text("DevIsland Settings")
                .padding()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("DevIsland launched")
        _ = AppState.shared // Force initialization to start HookSocketServer
        notchWindowController = NotchWindowController()
        notchWindowController?.showWindow(nil)
    }
}
