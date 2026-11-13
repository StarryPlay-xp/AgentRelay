import CryptoKit
import Darwin
import Foundation

// MARK: - 送给 Codex（设计方案第 11.1 节）

public enum CodexQueueOutcome: Sendable, Equatable {
    /// 排队成功；`ref` 是 Codex 给的排队编号（读不到时为 nil）
    case queued(ref: String?)
    /// 这次失败，可以重试
    case failed(String)
    /// 找不到 codex 程序，重试也没用
    case unavailable(String)
}

public protocol CodexQueueing: Sendable {
    func enqueue(threadID: String, message: String) -> CodexQueueOutcome
}

/// 调用 ChatGPT 内置的 codex 程序：`codex queue --thread <编号> --message <内容>`，不加 `--resume`。
public struct CodexCLI: CodexQueueing {
    /// ChatGPT 自带 codex 程序的默认位置
    public static let chatGPTDefault = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    /// 找 codex 程序的方法。测试必须传入假的程序路径，不能用默认的查找（会找到真的 ChatGPT）。
    public let executable: @Sendable () -> String?
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 30, executable: @escaping @Sendable () -> String?) {
        self.timeout = timeout
        self.executable = executable
    }

    /// 默认查找顺序：正在运行的后台服务那份 → 登记表里填的 → ChatGPT 默认位置 → PATH 里的 codex
    public static func locate(configuredPath: String?) -> String? {
        let fm = FileManager.default
        if let running = CodexAppServer.running()?.executable, fm.isExecutableFile(atPath: running) { return running }
        if let configuredPath, fm.isExecutableFile(atPath: configuredPath) { return configuredPath }
        if fm.isExecutableFile(atPath: chatGPTDefault) { return chatGPTDefault }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(dir) + "/codex"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func enqueue(threadID: String, message: String) -> CodexQueueOutcome {
        guard let exe = executable(), FileManager.default.isExecutableFile(atPath: exe) else { return .unavailable("找不到 codex 程序（ChatGPT 桌面版没装，或者路径不对）") }
        let (status, output) = Self.run(exe, ["queue", "--thread", threadID, "--message", message], timeout: timeout)
        guard status == 0 else {
            let brief = output.split(separator: "\n").first.map(String.init) ?? ""
            return .failed(status == -1 ? "codex queue 超时" : "codex queue 退出码 \(status)：\(brief.prefix(200))")
        }
        return .queued(ref: Self.parseQueueRef(output))
    }

    /// 从“Queued message <编号> for thread <编号>.”里取排队编号
    static func parseQueueRef(_ output: String) -> String? {
        guard let r = output.range(of: "Queued message ") else { return nil }
        let rest = output[r.upperBound...]
        let ref = rest.prefix { !$0.isWhitespace }
        return ref.isEmpty ? nil : String(ref)
    }

    /// 运行程序，返回（退出码，输出）。超时返回 -1。
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (127, "启动失败：\(error.localizedDescription)") }
        let collector = OutputCollector(pipe.fileHandleForReading)
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return (-1, collector.finish())
        }
        return (p.terminationStatus, collector.finish())
    }
}

/// 给 Codex 投递：同一收件会话串行（保证对方按发信顺序执行），不同会话并行（F21）；失败按间隔重试。
public final class CodexDispatcher: @unchecked Sendable {
    public typealias Report = @Sendable (_ messageID: String, _ outcome: CodexQueueOutcome, _ final: Bool) -> Void

    private let queuer: CodexQueueing
    private let retryDelays: [TimeInterval]
    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]

    /// - Parameter retryDelays: 失败后每次重试前等多久（默认 5、15、45 秒）
    public init(queuer: CodexQueueing, retryDelays: [TimeInterval] = [5, 15, 45]) {
        self.queuer = queuer
        self.retryDelays = retryDelays
    }

    private func queue(for thread: String) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let q = queues[thread] { return q }
        let q = DispatchQueue(label: "agentrelay.codex.\(thread)")
        queues[thread] = q
        return q
    }

    /// 投递一封信：第一次尝试同步完成并返回结果；失败时在后台按间隔重试，每次结果通过 `report` 告知。
    public func deliver(messageID: String, threadID: String, text: String, report: @escaping Report) -> CodexQueueOutcome {
        let q = queue(for: threadID)
        let first = q.sync { queuer.enqueue(threadID: threadID, message: text) }
        if case .failed = first, !retryDelays.isEmpty {
            scheduleRetry(attempt: 0, messageID: messageID, threadID: threadID, text: text, queue: q, report: report)
        } else {
            report(messageID, first, true)
        }
        return first
    }

    private func scheduleRetry(attempt: Int, messageID: String, threadID: String, text: String, queue: DispatchQueue, report: @escaping Report) {
        queue.asyncAfter(deadline: .now() + retryDelays[attempt]) { [self] in
            let outcome = queuer.enqueue(threadID: threadID, message: text)
            let isLast = attempt + 1 >= retryDelays.count
            if case .failed = outcome, !isLast {
                report(messageID, outcome, false)
                scheduleRetry(attempt: attempt + 1, messageID: messageID, threadID: threadID, text: text, queue: queue, report: report)
            } else {
                report(messageID, outcome, true)
            }
        }
    }
}

// MARK: - 送给 Claude（设计方案第 11.2 节）

/// “有新信”标记：`run/mailboxes/<信箱名>/new`，内容是未读数。relay-wait 只看这个标记，不读信件内容。
public struct ClaudeMailbox: Sendable {
    public let paths: RelayPaths

    public init(paths: RelayPaths) {
        self.paths = paths
    }

    public func setUnread(_ count: Int, mailbox: String) throws {
        let marker = paths.mailboxMarker(mailbox)
        if count <= 0 {
            unlink(marker)
            return
        }
        try FileSystem.makeDirectory(paths.mailbox(mailbox), mode: 0o700)
        try FileSystem.writeAtomically(Data(String(count).utf8), to: marker)
    }

    public func unreadMarker(mailbox: String) -> Int? {
        guard let s = try? String(contentsOfFile: paths.mailboxMarker(mailbox), encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 信箱主人标记里的短码；没有标记文件时为 nil，没有主人时为 `MailboxOwner.none`
    public func owner(mailbox: String) -> String? {
        guard let s = try? String(contentsOfFile: paths.mailboxOwner(mailbox), encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 写信箱主人标记；`token` 为 nil 表示这个信箱现在没有 Claude 会话在用。
    /// 没有主人、信箱目录也不存在时什么都不写；内容没变时不重写。
    public func setOwner(_ token: String?, mailbox: String) throws {
        let value = token ?? MailboxOwner.none
        if token == nil, !FileManager.default.fileExists(atPath: paths.mailbox(mailbox)) { return }
        if owner(mailbox: mailbox) == value { return }
        try FileSystem.makeDirectory(paths.mailbox(mailbox), mode: 0o700)
        try FileSystem.writeAtomically(Data(value.utf8), to: paths.mailboxOwner(mailbox))
    }

    /// 现有的信箱目录名（只返回合规的信箱名）
    public func mailboxNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.mailboxes)) ?? []
        return names.filter { (try? MailboxName.validate($0)) != nil }
    }
}

/// 信箱主人的短码：由会话编号算出，不在命令里露出编号原文。
/// 交接、改名、停用后信箱换了主人（或没了主人），带旧短码的等信命令会自己结束。
public enum MailboxOwner {
    /// 信箱现在没有 Claude 会话在用
    public static let none = "-"

    public static func token(sessionID: String) -> String {
        SHA256.hash(data: Data(sessionID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func token(for session: SessionRow) -> String { token(sessionID: session.sessionID) }
}

public protocol WaitDetecting: Sendable {
    /// 这个信箱现在有没有当前主人的 relay-wait 在等（`owner` 是主人的短码）
    func isWaiting(mailbox: String, owner: String) -> Bool
}

/// 看本用户进程里有没有 `relay-wait --mailbox <信箱名> [--owner <短码>]`。
/// 不要求 relay-wait 写心跳文件，避开 Claude 沙盒可能不让写文件的问题。
/// 带短码的只算短码相符的；不带短码的（旧版等信命令）分不清是谁在等，照旧算在等。
public struct ProcessWaitDetector: WaitDetecting {
    public init() {}

    /// 从 relay-wait 的参数里取出信箱名和短码；不是合法的等信参数时返回 nil
    public static func waiter(arguments args: [String]) -> (mailbox: String, owner: String?)? {
        guard let i = args.firstIndex(of: "--mailbox"), i + 1 < args.count else { return nil }
        var owner: String?
        if let j = args.firstIndex(of: "--owner"), j + 1 < args.count { owner = args[j + 1] }
        return (args[i + 1], owner)
    }

    private static func waiters() -> [(mailbox: String, owner: String?)] {
        Processes.find({ _, path, _ in (path as NSString).lastPathComponent == "relay-wait" }).compactMap {
            Processes.arguments(of: $0).flatMap(waiter(arguments:))
        }
    }

    static func matches(_ w: (mailbox: String, owner: String?), mailbox: String, owner: String) -> Bool {
        w.mailbox == mailbox && (w.owner == nil || w.owner == owner)
    }

    /// 这些会话里，当前有自己的 relay-wait 在等的信箱名（界面刷新时一次扫完，不必逐个信箱扫）
    public static func waitingMailboxes(for sessions: [SessionRow]) -> Set<String> {
        let all = waiters()
        return Set(sessions.filter { s in
            all.contains { matches($0, mailbox: s.mailbox, owner: MailboxOwner.token(for: s)) }
        }.map(\.mailbox))
    }

    public func isWaiting(mailbox: String, owner: String) -> Bool {
        Self.waiters().contains { Self.matches($0, mailbox: mailbox, owner: owner) }
    }
}
