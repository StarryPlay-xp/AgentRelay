import AppKit
import Foundation
import RelayCore

/// 应用里的中转核心（设计方案第 5.1 节）：取单实例锁、建 bin 链接、打开数据库、开本机通话口、定时检查。
/// 代替第 2 步开发用的 relayd。
@MainActor
final class AppRuntime {
    let paths: RelayPaths
    private(set) var store: Store?
    private(set) var service: RelayService?
    private(set) var discovery = ProjectDiscovery.resolve()
    /// 启动失败的原因（例如已经有一个 AgentRelay 在运行）
    private(set) var startupError: String?
    /// 同一个数据目录已经有一个 AgentRelay 在运行
    private(set) var alreadyRunning = false
    /// bin 链接的问题（例如应用被系统放在“应用转移”的临时位置）
    private(set) var helperProblem: String?

    private var server: SocketServer?
    private var instanceLock: InstanceLock?
    private var timer: Timer?
    /// 有新通知时调用（界面借此立即刷新）
    var onNotice: (@MainActor () -> Void)?

    init() {
        paths = Self.resolvePaths()
    }

    /// 数据放在哪：环境变量 AGENTRELAY_HOME 优先；其次是启动参数 -AgentRelayHome（Xcode 的构建方案里给开发用）；都没有就用默认位置
    static func resolvePaths() -> RelayPaths {
        var env = ProcessInfo.processInfo.environment
        if env["AGENTRELAY_HOME"]?.isEmpty ?? true, let home = UserDefaults.standard.string(forKey: "AgentRelayHome"), !home.isEmpty {
            env["AGENTRELAY_HOME"] = home
        }
        return RelayPaths.resolve(environment: env)
    }

    var isDevelopmentHome: Bool { paths != RelayPaths.resolve(environment: [:]) }

    func start() {
        do {
            try paths.prepare()
            instanceLock = try InstanceLock(path: paths.lock)
        } catch let e as RelayError {
            alreadyRunning = e.message.contains("已经有")
            startupError = alreadyRunning ? "已经有一个 AgentRelay 在运行。" : e.message
            return
        } catch {
            startupError = "\(error)"
            return
        }
        helperProblem = installHelperLinks()
        do {
            let store = try Store(path: paths.database)
            let codex = CodexCLI(executable: { CodexCLI.locate(configuredPath: store.codexPath()) })
            let service = RelayService(
                paths: paths, store: store, registry: DatabaseRegistry(store: store),
                resolver: IdentityResolver(locator: SessionRecordLocator(paths: ExternalPaths.resolve())),
                limits: { store.limits() }, dispatcher: CodexDispatcher(queuer: codex),
                notify: { notice in
                    Notifier.shared.post(notice)
                    Task { @MainActor [weak self] in self?.onNotice?() }
                })
            let server = SocketServer(paths: paths, policy: .strict(relayMCP: paths.bin + "/relay-mcp"),
                                      onReject: { text in
                                          let n = Notice(kind: "拒绝", text: text)
                                          try? store.addEvent(kind: n.kind, summary: n.text, at: Date())
                                          Notifier.shared.post(n)
                                      }) { req, platform in
                service.handle(req, peerPlatform: platform)
            }
            try server.start()
            self.store = store
            self.service = service
            self.server = server
        } catch let e as RelayError {
            startupError = e.message
            return
        } catch {
            startupError = "\(error)"
            return
        }
        // 定时检查放在主线程（第 2 步 relayd 曾因放在其他线程而崩溃）
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.service?.runPeriodicChecks() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        service?.runPeriodicChecks()
    }

    func stop() {
        timer?.invalidate()
        server?.stop()
    }

    /// 在 bin/ 下建指向应用包内两个程序的符号链接（设计方案第 6 节）；链接指错了就改正。返回问题说明，没问题返回 nil。
    func installHelperLinks() -> String? {
        let bundle = Bundle.main.bundlePath
        if bundle.contains("/AppTranslocation/") {
            return "AgentRelay 现在运行在系统的临时位置（从“下载”等文件夹直接打开时会这样），没有建立程序链接。请把 AgentRelay 拖进“应用程序”文件夹后再打开。"
        }
        let fm = FileManager.default
        for name in ["relay-mcp", "relay-wait"] {
            let target = bundle + "/Contents/Helpers/" + name
            let link = paths.bin + "/" + name
            guard fm.isExecutableFile(atPath: target) else { return "应用包里缺少 \(name)，请重新安装 AgentRelay。" }
            if let current = try? fm.destinationOfSymbolicLink(atPath: link), current == target { continue }
            try? fm.removeItem(atPath: link)
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            } catch {
                return "建立程序链接失败：\(link)"
            }
        }
        return nil
    }
}
