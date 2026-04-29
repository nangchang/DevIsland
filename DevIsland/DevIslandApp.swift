import SwiftUI

@main
struct DevIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: state.pendingCount > 0 ? "bell.badge.fill" : "bell.fill")
                if state.pendingCount > 0 {
                    Text("\(state.pendingCount)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
        }
    }
}

// MARK: - Menu Bar Menu

struct MenuBarMenu: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        if state.pendingItems.isEmpty {
            Text("대기 중인 요청 없음")
                .foregroundStyle(.secondary)
        } else {
            ForEach(state.pendingItems) { item in
                HStack(spacing: 6) {
                    Image(systemName: toolInfo(for: item.toolName).icon)
                        .foregroundStyle(toolInfo(for: item.toolName).color)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.toolName.isEmpty ? "Unknown" : item.toolName)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Divider()
        }

        if state.isNotchExpanded {
            Button("Approve  ⌘⇧Y") { state.approve() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Deny  ⌘⇧N") { state.deny() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
        }

        Button("Quit DevIsland") {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppState.shared
        notchWindowController = NotchWindowController()
        notchWindowController?.showWindow(nil)
    }
}
