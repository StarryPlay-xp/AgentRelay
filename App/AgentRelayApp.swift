import SwiftUI

/// AgentRelay 桌面应用：菜单栏常驻（设计方案第 4、16 节）。
@main
struct AgentRelayApp: App {
    var body: some Scene {
        MenuBarExtra("AgentRelay", systemImage: "arrow.left.arrow.right.circle") {
            Text("AgentRelay")
            Divider()
            Button("退出 AgentRelay") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
