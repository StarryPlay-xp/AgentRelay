import AppKit
import SwiftUI

/// AgentRelay 桌面应用：菜单栏常驻，中转核心在应用里运行（设计方案第 4、5.1、16 节）。
@main
struct AgentRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.paused ? "pause.circle" : "arrow.left.arrow.right.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(runtime: AppRuntime())

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        if model.runtime.alreadyRunning {
            let alert = NSAlert()
            alert.messageText = "AgentRelay 已经在运行"
            alert.informativeText = "在菜单栏里可以找到它。这个窗口会自动关闭。"
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        Notifier.shared.setUp()
        // 被 kill 等信号结束时也正常收尾（关掉本机通话口）
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApplication.shared.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.runtime.stop()
    }
}

/// 菜单栏面板：运行或暂停状态、今天的信件数、待处理数、全部暂停、退出
struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.runtime.startupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Label(model.paused ? "已暂停全部传话" : "正在运行", systemImage: model.paused ? "pause.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.paused ? .orange : .green)
                Text("今天 \(model.todayCount) 封信 · 待处理 \(model.attention.count) 项")
                    .foregroundStyle(.secondary)
                if let problem = model.runtime.helperProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                if model.runtime.isDevelopmentHome {
                    Text("开发数据目录：\(model.runtime.paths.home)").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("全部暂停", isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
            }
            Divider()
            Button("退出 AgentRelay") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }
}
