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
    /// 现在有 relay-wait 在等的信箱
    var waiting: Set<String> = []
    /// 最近一次操作的错误，界面上弹出
    var errorMessage: String?

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
        waiting = ProcessWaitDetector.waitingMailboxes()
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
}
