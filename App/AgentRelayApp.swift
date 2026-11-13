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
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("AgentRelay", id: "main") {
            MainWindow(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
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
        AppLog.write(model.isRunning ? "启动，数据目录 \(model.runtime.paths.home)" : "启动失败：\(model.runtime.startupError ?? "")",
                     paths: model.runtime.paths)
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
        // 因为已有一份在运行而被拦下的这份从没启动过，日志里写明，免得和正在运行那份的“退出”混淆
        AppLog.write(model.runtime.alreadyRunning ? "已有一份 AgentRelay 在用这个数据目录，这次打开的副本没有启动，直接退出" : "退出",
                     paths: model.runtime.paths)
    }
}

/// 菜单栏图标：信封带分叉箭头；有待处理时换成带圆点的信封，暂停时是暂停符号。
/// 第一次使用（还没有分组）时，启动后自动打开主窗口，引导你登记项目
struct MenuBarLabel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("AgentRelay")
            .task(id: model.started) {
                guard model.started, model.isRunning, model.groups.isEmpty, !model.openedAtLaunch else { return }
                model.openedAtLaunch = true
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
    }

    private var symbol: String {
        if model.runtime.startupError != nil { return "exclamationmark.triangle" }
        if model.paused { return "pause.circle" }
        return model.attention.isEmpty ? "envelope.arrow.triangle.branch" : "envelope.badge"
    }
}

/// 菜单栏面板：顶边是航空信条纹；一句话说清今天的信件数和待处理数，列出最近几件待处理，下面是全部暂停、打开主窗口、退出
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AirmailStripe(height: 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("AgentRelay").font(Fonts.wordmark(15)).foregroundStyle(Palette.ink)
                    Spacer()
                    RunStateLabel(model: model)
                }
                if let error = model.runtime.startupError {
                    Text(error)
                        .font(Fonts.small)
                        .foregroundStyle(Palette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                } else {
                    status
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 16)
            Hairline()
            VStack(spacing: 0) {
                if model.runtime.startupError == nil {
                    HStack {
                        Text("全部暂停").font(Fonts.body).foregroundStyle(Palette.ink)
                        Spacer()
                        Toggle("全部暂停", isOn: Binding(get: { model.paused }, set: { on in model.setPaused(on) }))
                            .inkSwitch()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                }
                MenuRow(title: "打开主窗口", key: "o", action: openMain)
                MenuRow(title: "退出 AgentRelay", key: "q") { NSApplication.shared.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 300)
        .background(Palette.paper)
        .tint(Palette.ink)
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Headline.lines(model), id: \.self) { Text($0) }
        }
        .font(Fonts.display(18))
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 18)
        if !model.attention.isEmpty {
            Button(action: openMain) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.attention.prefix(3)) { item in
                        HStack(spacing: 10) {
                            Capsule().fill(Headline.color(item)).frame(width: 2, height: 13)
                            Text(item.title).font(Fonts.small).foregroundStyle(Palette.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.time(item.time)).font(Fonts.tiny).monospacedDigit().foregroundStyle(Palette.ink3)
                        }
                    }
                    if model.attention.count > 3 {
                        Text("还有 \(model.attention.count - 3) 件，在主窗口里处理").font(Fonts.tiny).foregroundStyle(Palette.ink3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在主窗口里处理")
            .padding(.top, 14)
        }
        if let problem = model.runtime.helperProblem {
            Text(problem)
                .font(Fonts.tiny)
                .foregroundStyle(Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        if model.runtime.isDevelopmentHome {
            Text("开发数据目录：\(model.runtime.paths.home)")
                .font(Fonts.tiny)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 12)
        }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

/// 面板里的一行操作：悬停时铺淡底，右边是快捷键
private struct MenuRow: View {
    let title: String
    /// ⌘ 加这个键
    let key: Character
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(Fonts.body).foregroundStyle(Palette.ink)
                Spacer()
                Text("⌘" + String(key).uppercased()).font(Fonts.small).foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background(hovering ? Palette.wash : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        .onHover { hovering = $0 }
    }
}
