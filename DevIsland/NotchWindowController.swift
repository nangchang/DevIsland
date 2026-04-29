import AppKit
import SwiftUI

class NotchWindowController: NSWindowController {
    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 1 // Above the menu bar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        self.init(window: panel)
        
        // Setup SwiftUI View
        let notchView = NSHostingView(rootView: NotchView())
        panel.contentView = notchView
        
        positionUnderNotch()
    }
    
    func positionUnderNotch() {
        guard let window = self.window, let screen = NSScreen.main else { return }
        
        // Calculate notch position (top center)
        let screenRect = screen.frame
        let windowRect = window.frame
        let x = (screenRect.width - windowRect.width) / 2
        let y = screenRect.height - windowRect.height
        
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct NotchView: View {
    @ObservedObject var state = AppState.shared
    
    var body: some View {
        VStack {
            ZStack {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: state.isNotchExpanded ? 30 : 15,
                    bottomTrailingRadius: state.isNotchExpanded ? 30 : 15,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(Color.black)
                
                VStack {
                    HStack {
                        Text("DevIsland")
                            .foregroundColor(.white)
                            .font(.caption)
                            .bold()
                        Spacer()
                    }
                    
                    if state.isNotchExpanded {
                        Text(state.currentMessage)
                            .foregroundColor(.white)
                            .font(.body)
                            .padding(.top, 5)
                            .lineLimit(2)
                        
                        HStack {
                            Button("Approve") {
                                state.approve()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            
                            Button("Deny") {
                                state.deny()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding()
            }
            .frame(width: state.isNotchExpanded ? 400 : 150, height: state.isNotchExpanded ? 150 : 30)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: state.isNotchExpanded)
            .onTapGesture {
                state.isNotchExpanded.toggle()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Enable drag region
        .onAppear {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
