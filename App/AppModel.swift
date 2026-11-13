import Foundation
import Observation
import RelayCore

/// 界面用的数据：每 2 秒以及每次操作后从数据库刷新。所有修改都经过 RelayCore 的方法。
@Observable
@MainActor
final class AppModel {
    let runtime: AppRuntime

    var paused = false
    var todayCount = 0
    var attention: [AttentionItem] = []
    var groups: [GroupRow] = []
    var projects: [ProjectRow] = []
    var sessions: [SessionRow] = []
    var messages: [MessageRow] = []
    /// 当前主人正在用 relay-wait 等信的信箱（旧会话残留的等信不算）
    var waiting: Set<String> = []
    /// 最近一次操作的错误，界面上弹出
    var errorMessage: String?
    /// 本次启动是否已经自动打开过主窗口
    var openedAtLaunch = false
    /// 中转核心启动流程已经走完（成功或失败），界面据此做启动后的事
    var started = false

    @ObservationIgnored private var timer: Timer?

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    var store: Store? { runtime.store }
    var service: RelayService? { runtime.service }
    var isRunning: Bool { runtime.startupError == nil && runtime.service != nil }

    func start() {
        runtime.onNotice = { [weak self] in self?.refresh() }
        runtime.start()
        refresh()
        started = true
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard let store, let service else { return }
        paused = store.isPaused
        todayCount = (try? store.countMessagesToday()) ?? 0
        attention = (try? service.attentionItems()) ?? []
        groups = (try? store.groups()) ?? []
        projects = (try? store.projects()) ?? []
        sessions = (try? store.sessions()) ?? []
        messages = (try? store.recentMessages(limit: 500)) ?? []
        waiting = ProcessWaitDetector.waitingMailboxes(for: sessions.filter { $0.platform == .claude && $0.status == .active })
    }

    /// 执行一个修改操作；出错时把原因显示给你
    func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch let e as RelayError {
            errorMessage = e.message
        } catch {
            errorMessage = "\(error)"
        }
        refresh()
    }

    func setPaused(_ on: Bool) {
        perform { try service?.setPaused(on) }
    }

    /// 某个项目当前所在的分组名
    func groupName(ofProject name: String) -> String? {
        projects.first { $0.name == name }?.groupName
    }

    /// 项目名在登记表里必须唯一：两边同名时加上平台，还重复就加序号
    func uniqueProjectName(_ base: String, platform: Platform) -> String {
        let taken = Set(projects.map(\.name))
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !taken.contains(trimmed) { return trimmed }
        let withPlatform = "\(trimmed)（\(platform.displayName)）"
        if !taken.contains(withPlatform) { return withPlatform }
        var i = 2
        while taken.contains("\(withPlatform) \(i)") { i += 1 }
        return "\(withPlatform) \(i)"
    }

    /// 和会话看到的一样的信封
    func envelope(for m: MessageRow) -> Envelope {
        Envelope(messageID: m.id, chainID: m.chainID, hop: m.hop, hopLimit: store?.limits().hopLimit ?? Limits().hopLimit,
                 fromMailbox: m.fromMailbox, fromPlatform: m.fromPlatform, fromProject: m.fromProject,
                 needsReply: m.needsReply, subject: m.subject)
    }
}
