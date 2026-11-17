import Foundation
import Observation
import RelayCore
import ServiceManagement

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
    /// 两边的接入状态（查一次要运行 codex，所以不跟着 2 秒刷新，只在打开“接入”页和操作后查）
    var integrationStatus: [Platform: IntegrationStatus] = [:]
    /// 两边最近一次操作（安装、核对、卸载）的结果
    var integrationReports: [Platform: IntegrationReport] = [:]
    /// 正在查或正在操作的平台
    var integrationBusy: Set<Platform> = []
    /// 最近的配置改动记录
    var configChanges: [ConfigChangeRow] = []
    /// Codex 钩子（立即引导）：全局一份，加上装过钩子的项目文件夹
    var hookStatuses: [HookStatus] = []
    var hookBusy = false
    var hookReport: IntegrationReport?
    /// 完全卸载进行到哪一步、每步的结果
    var uninstallPhase: UninstallPhase = .idle
    var uninstallSteps: [UninstallStep] = []

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
        refreshIntegrations()
    }

    /// 停掉 2 秒一次的刷新（完全卸载关掉数据库之前）
    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
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

// MARK: - 接入向导和完全卸载（设计方案第 13 节、第 6.3 节）

extension AppModel {
    enum IntegrationOperation: Sendable { case install, verify, uninstall }

    enum UninstallPhase: Equatable { case idle, running, failed, done }

    /// 在后台查两边的接入状态（要运行 codex，不能放在主线程）
    func refreshIntegrations(_ platforms: [Platform] = [.codex, .claude]) {
        guard let integrations = runtime.integrations else { return }
        configChanges = (try? store?.configChanges(limit: 20)) ?? []
        for p in platforms where !integrationBusy.contains(p) {
            integrationBusy.insert(p)
            Task.detached {
                let st = integrations.status(p)
                await MainActor.run { [weak self] in
                    self?.integrationStatus[p] = st
                    self?.integrationBusy.remove(p)
                }
            }
        }
    }

    /// 在后台安装、核对或卸载，做完再查一次状态
    func runIntegration(_ op: IntegrationOperation, on p: Platform) {
        guard let integrations = runtime.integrations, !integrationBusy.contains(p) else { return }
        integrationBusy.insert(p)
        integrationReports[p] = nil
        Task.detached {
            let report: IntegrationReport
            switch op {
            case .install: report = integrations.install(p)
            case .verify: report = integrations.verify(p)
            case .uninstall: report = integrations.uninstall(p)
            }
            let st = integrations.status(p)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.integrationReports[p] = report
                self.integrationStatus[p] = st
                self.integrationBusy.remove(p)
                self.configChanges = (try? self.store?.configChanges(limit: 20)) ?? []
            }
        }
    }

    /// 在后台查钩子的安装状态（全局和装过钩子的项目文件夹）
    func refreshHooks() {
        guard let integrations = runtime.integrations, !hookBusy else { return }
        hookBusy = true
        Task.detached {
            let list = [integrations.hookStatus(.global)] + integrations.projectHookScopes().map { integrations.hookStatus($0) }
            await MainActor.run { [weak self] in
                self?.hookStatuses = list
                self?.hookBusy = false
            }
        }
    }

    /// 在后台安装、核对或移除钩子，做完再查一次
    func runHooks(_ op: IntegrationOperation, scope: HookScope) {
        guard let integrations = runtime.integrations, !hookBusy else { return }
        hookBusy = true
        hookReport = nil
        let store = store
        Task.detached {
            let report: IntegrationReport
            switch op {
            case .install: report = integrations.installHooks(scope)
            case .verify: report = integrations.verifyHooks(scope, lastReport: try? store?.lastHookReport())
            case .uninstall: report = integrations.uninstallHooks(scope)
            }
            let list = [integrations.hookStatus(.global)] + integrations.projectHookScopes().map { integrations.hookStatus($0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hookReport = report
                self.hookStatuses = list
                self.hookBusy = false
                self.configChanges = (try? self.store?.configChanges(limit: 20)) ?? []
            }
        }
    }

    /// 两边都查过了、却一边都没接入：概览提醒你去“接入”页
    var needsSetup: Bool {
        guard integrationStatus.count == 2 else { return false }
        return !integrationStatus.values.contains { $0.state == .installed }
    }
}

extension AppModel {
    /// 完全卸载（设计方案第 6.3 节）：先从两边移除传话工具（失败就停，什么都不删）；再关掉“登录时启动”、
    /// 停掉中转服务、关掉数据库，删 bin/、run/；`deleteData` 为真时连数据库、备份、日志和偏好设置一起删。做完由你点“退出”。
    func fullUninstall(deleteData: Bool) {
        guard let integrations = runtime.integrations, uninstallPhase != .running else { return }
        uninstallPhase = .running
        uninstallSteps = []
        Task.detached {
            let steps = FullUninstall.removeIntegrations(integrations)
            await MainActor.run { [weak self] in self?.finishUninstall(removed: steps, deleteData: deleteData) }
        }
    }

    private func finishUninstall(removed: [UninstallStep], deleteData: Bool) {
        uninstallSteps = removed
        guard removed.allSatisfy({ $0.ok }) else {
            uninstallPhase = .failed
            refreshIntegrations()
            return
        }
        uninstallSteps.append(unregisterLoginItem())
        stopRefreshing()
        let paths = runtime.paths
        runtime.shutdownForUninstall()
        let deleted = FullUninstall.deleteFiles(paths: paths, deleteData: deleteData)
        uninstallSteps += deleted
        if deleteData, deleted.allSatisfy({ $0.ok }) { uninstallSteps.append(removePreferences()) }
        uninstallPhase = uninstallSteps.allSatisfy { $0.ok } ? .done : .failed
    }

    private func unregisterLoginItem() -> UninstallStep {
        let service = SMAppService.mainApp
        guard service.status == .enabled || service.status == .requiresApproval else {
            return UninstallStep(title: "关掉登录时启动", ok: true, detail: "本来就没打开")
        }
        do {
            try service.unregister()
            return UninstallStep(title: "关掉登录时启动", ok: true, detail: "已从登录项里移除")
        } catch {
            return UninstallStep(title: "关掉登录时启动", ok: false, detail: "\(error.localizedDescription)。可以到“系统设置 › 通用 › 登录项”里手动移除。")
        }
    }

    /// 偏好设置和系统保存的窗口状态
    private func removePreferences() -> UninstallStep {
        guard let id = Bundle.main.bundleIdentifier else { return UninstallStep(title: "删除偏好设置", ok: true, detail: "没有应用标识") }
        UserDefaults.standard.removePersistentDomain(forName: id)
        let saved = RelayPaths.userHome() + "/Library/Saved Application State/\(id).savedState"
        try? FileManager.default.removeItem(atPath: saved)
        return UninstallStep(title: "删除偏好设置", ok: true, detail: id)
    }
}
