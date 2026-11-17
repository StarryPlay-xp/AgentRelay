// relayd：开发用中转进程，第 3 步由桌面应用取代。
//
// 用法：relayd [--home <AGENTRELAY_HOME>] [--codex <codex 程序路径>] [--dev-relax-peer-check] [--no-console] [--check-interval <秒>]
//
//   --home                  运行时文件和数据放在这个目录（等同于设置 AGENTRELAY_HOME）
//   --codex                 固定使用这个 codex 程序（测试时指向假脚本，避免把信送进真实的 Codex）
//   --dev-relax-peer-check  只核对对端是同一用户，不核对 relay-mcp 路径和父进程签名（仅开发、测试）
//   --no-console            不读标准输入里的控制台命令，收到 SIGINT/SIGTERM 时退出
//   --check-interval        定时检查的间隔，默认 30 秒（测试时调短）
//
// 控制台命令：help、status、sessions、messages [条数]、events [条数]、pause、resume、handoff <信箱名>、reload、quit
import Darwin
import Foundation
import RelayCore

let printLock = NSLock()
nonisolated(unsafe) var logHandle: FileHandle?

func say(_ text: String) {
    printLock.lock()
    defer { printLock.unlock() }
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func stamp(_ d: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

func usage() -> Never {
    say("用法：relayd [--home <目录>] [--codex <codex 程序路径>] [--dev-relax-peer-check] [--no-console] [--check-interval <秒>]")
    exit(2)
}

// MARK: 参数

var home: String?
var codexPath: String?
var relaxed = false
var console = true
var checkInterval: Double = 30
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--home": home = it.next() ?? { usage() }()
    case "--codex": codexPath = it.next() ?? { usage() }()
    case "--dev-relax-peer-check": relaxed = true
    case "--no-console": console = false
    case "--check-interval":
        guard let v = it.next().flatMap(Double.init), v > 0 else { usage() }
        checkInterval = v
    default: usage()
    }
}

var env = ProcessInfo.processInfo.environment
if let home { env["AGENTRELAY_HOME"] = home }
let paths = RelayPaths.resolve(environment: env)

// MARK: 启动

let lock: InstanceLock
let store: Store
do {
    try paths.prepare()
    lock = try InstanceLock(path: paths.lock)
    store = try Store(path: paths.database)
} catch {
    say("启动失败：\(error)")
    exit(1)
}

let logPath = paths.logs + "/relayd.log"
if !FileManager.default.fileExists(atPath: logPath) {
    FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
}
logHandle = FileHandle(forWritingAtPath: logPath)
logHandle?.seekToEndOfFile()

/// 通知：打印到控制台并写日志（日志里不写信件正文，通知本身也不含正文）
let notify: @Sendable (Notice) -> Void = { n in
    let line = "[\(stamp())]【\(n.kind)】\(n.text)"
    say(line)
    printLock.lock()
    logHandle?.write(Data((line + "\n").utf8))
    printLock.unlock()
}

let registry = RegistryStore(path: paths.registry)
let fixedCodex = codexPath
let codex = CodexCLI(executable: {
    if let fixedCodex { return fixedCodex }
    return CodexCLI.locate(configuredPath: registry.snapshot().registry.codexPath)
})
let service = RelayService(
    paths: paths, store: store, registry: registry,
    resolver: IdentityResolver(locator: SessionRecordLocator(paths: ExternalPaths.resolve(environment: env))),
    dispatcher: CodexDispatcher(queuer: codex, checker: CodexAppServerQueueChecker(
        codexHome: CodexAppServerQueueChecker.defaultCodexHome(environment: env), executable: codex.executable)),
    handoffHint: { "确认请在 relayd 控制台输入：handoff \($0)" }, notify: notify)

let policy: PeerPolicy = relaxed ? .relaxed : .strict(relayMCP: paths.bin + "/relay-mcp")
let server = SocketServer(paths: paths, policy: policy, onReject: { notify(Notice(kind: "拒绝", text: $0)) }) { req, peer in
    service.handle(req, peer: peer)
}
do { try server.start() } catch {
    say("启动失败：\(error)")
    exit(1)
}

// 定时检查放在主队列：顶层代码属于主线程，放到其他队列运行会被 Swift 6 的运行时检查判为越界而退出
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
timer.setEventHandler { service.runPeriodicChecks() }
timer.resume()
service.runPeriodicChecks()

func shutdown(_ code: Int32) -> Never {
    server.stop()
    say("中转核心已停止。")
    exit(code)
}

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { shutdown(0) }
    src.resume()
    _ = Unmanaged.passRetained(src)
}

let reg = registry.snapshot()
say("AgentRelay 中转核心已启动（开发用 relayd）。")
say("运行目录：\(paths.home)")
say("登记表：\(paths.registry)" + (FileManager.default.fileExists(atPath: paths.registry)
    ? "（\(reg.registry.groups.count) 个分组，\(reg.registry.projects.count) 个项目）" : "（还不存在，请按 README 的格式写好后输入 reload）"))
if let e = reg.error { say("登记表有错：\(e.message)") }
say(relaxed ? "对端核对：放宽（只核对用户，仅供开发测试）" : "对端核对：正式（核对 relay-mcp 路径和父进程签名）")
if let codexPath { say("codex 程序：固定使用 \(codexPath)") }
if console { say("输入 help 查看命令。") }

// MARK: 控制台


func runCommand(_ line: String) {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let cmd = parts.first else { return }
    let n = parts.count > 1 ? Int(parts[1]) ?? 20 : 20
    do {
        switch cmd {
        case "help":
            say("命令：status、sessions、messages [条数]、events [条数]、pause、resume、handoff <信箱名>、reload、quit")
        case "status":
            let r = registry.snapshot().registry
            let active = try store.sessions(status: .active).count
            let hour = try store.countMessages(since: Date().addingTimeInterval(-3_600))
            say("传话：\(store.isPaused ? "已暂停" : "正常")；登记表 \(r.groups.count) 个分组、\(r.projects.count) 个项目；在用会话 \(active) 个；最近一小时 \(hour) 封信")
        case "sessions":
            let rows = try store.sessions()
            if rows.isEmpty { say("还没有会话登记。") }
            for s in rows {
                say("\(s.mailbox)｜\(s.platform.displayName) · \(s.project)｜分组 \(s.group)｜\(s.status.rawValue)｜身份来自 \(s.identitySource.rawValue)｜最后活动 \(stamp(s.lastActiveAt))")
            }
        case "messages":
            let rows = try store.recentMessages(limit: n)
            if rows.isEmpty { say("还没有信。") }
            for m in rows.reversed() {
                let preview = m.body.replacingOccurrences(of: "\n", with: " ").prefix(40)
                let how = RelayService.deliveryReceipt(m).map { "｜\($0)" } ?? ""
                say("\(m.id)｜\(stamp(m.createdAt))｜\(m.fromMailbox) → \(m.toMailbox)｜\(m.chainID) 第 \(m.hop) 次｜\(RelayService.statusName(m.status))\(how)\(m.error.map { "（\($0)）" } ?? "")｜\(preview)")
            }
        case "events":
            for e in try store.events(limit: n).reversed() { say("\(stamp(e.time))｜\(e.kind)｜\(e.summary)") }
        case "pause":
            try service.setPaused(true)
            say("已暂停全部传话。")
        case "resume":
            try service.setPaused(false)
            say("已恢复传话（暂停期间被拒绝的信不会补发）。")
        case "handoff":
            guard parts.count == 2 else { say("用法：handoff <信箱名>"); return }
            say(try service.confirmHandoff(mailbox: parts[1]))
        case "reload":
            let r = registry.snapshot()
            say(r.error.map { "登记表有错：\($0.message)" } ?? "登记表：\(r.registry.groups.count) 个分组，\(r.registry.projects.count) 个项目。")
        case "quit", "exit":
            shutdown(0)
        default:
            say("不认识的命令：\(cmd)。输入 help 查看命令。")
        }
    } catch let e as RelayError {
        say(e.message)
    } catch {
        say("出错：\(error)")
    }
}

if console {
    Thread.detachNewThread {
        while let line = readLine() {
            let l = line.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async { runCommand(l) }
        }
        DispatchQueue.main.async { shutdown(0) }
    }
}

withExtendedLifetime(lock) { dispatchMain() }
