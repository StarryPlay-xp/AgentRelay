import Foundation

/// relay-wait 的逻辑（设计方案第 5.3 节）：盯着信箱目录里的“有新信”标记，出现就打印一句提示并结束，
/// Claude 会话因后台命令结束而被叫醒。只看标记里的未读数，不读信件内容；不设时间上限（F13）。
/// 带主人短码时，信箱换了主人（交接、改名、停用）就自己结束，免得旧会话跟着被叫醒。
public struct Waiter: Sendable {
    public let paths: RelayPaths
    public let mailbox: String
    /// 启动它的会话的短码（`MailboxOwner.token`）；nil 表示旧版等信命令，不核对主人
    public let owner: String?
    public let interval: TimeInterval

    public init(paths: RelayPaths, mailbox: String, owner: String? = nil, interval: TimeInterval = 1) {
        self.paths = paths
        self.mailbox = mailbox
        self.owner = owner
        self.interval = interval
    }

    public enum Outcome: Equatable, Sendable {
        /// 有新信
        case newMail(Int)
        /// 信箱已经不归启动它的会话了
        case notOwner
        /// 参数或环境不对
        case invalid(String)
    }

    public func check() throws {
        try MailboxName.validate(mailbox)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: paths.run, isDirectory: &isDir), isDir.boolValue else {
            throw RelayError(.relayNotRunning, "找不到 AgentRelay 的运行目录，AgentRelay 可能还没运行过")
        }
    }

    /// 一直等到有新信（或信箱换了主人、AgentRelay 被卸载）
    public func wait() -> Outcome {
        do { try check() } catch let e as RelayError { return .invalid(e.message) } catch { return .invalid("\(error)") }
        while true {
            if let outcome = poll() { return outcome }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// 看一次：该结束时返回结果，还要接着等时返回 nil
    public func poll() -> Outcome? {
        let box = ClaudeMailbox(paths: paths)
        // 先核对主人再看新信：信箱刚换主人时，给新主人的信不能叫醒旧会话。
        // 没有主人标记（旧版 AgentRelay 或标记还没写）时照常等
        if let owner, let current = box.owner(mailbox: mailbox), current != owner { return .notOwner }
        if let n = box.unreadMarker(mailbox: mailbox), n > 0 { return .newMail(n) }
        // AgentRelay 被卸载（运行目录被删）后不再空等
        if !FileManager.default.fileExists(atPath: paths.run) {
            return .invalid("AgentRelay 的运行目录不见了（可能已卸载），停止等信")
        }
        return nil
    }

    public static func message(for n: Int) -> String {
        "你有 \(n) 封新信，请调用 relay_inbox 读取；读完后再重新在后台运行等信命令。"
    }

    public static func notOwnerMessage(mailbox: String) -> String {
        "信箱 \(mailbox) 已经不归本会话了（可能已由新会话接手、改了名或被用户停用），停止等信。可以调用 relay_status 查看本会话现在的情况。"
    }
}

/// relay-wait 命令行入口（包里的 relay-wait 和应用内嵌的 relay-wait 都调用它）。
/// 用法：relay-wait --mailbox <信箱名> [--owner <短码>] [--home <AGENTRELAY_HOME>]
/// 有新信时打印一句提示并以 0 退出；参数或环境不对以 2 退出；信箱已经不归本会话时以 3 退出。
public enum RelayWaitCommand {
    public static let usage = "用法：relay-wait --mailbox <信箱名> [--owner <短码>] [--home <目录>]"

    public struct Options: Equatable, Sendable {
        public var mailbox: String
        public var owner: String?
        public var home: String?

        public init(mailbox: String, owner: String? = nil, home: String? = nil) {
            self.mailbox = mailbox
            self.owner = owner
            self.home = home
        }
    }

    /// 解析参数（不含程序名）；不合法时返回 nil
    public static func parse(_ arguments: [String]) -> Options? {
        var mailbox: String?
        var owner: String?
        var home: String?
        var it = arguments.makeIterator()
        while let a = it.next() {
            switch a {
            case "--mailbox": guard let v = it.next() else { return nil }; mailbox = v
            case "--owner": guard let v = it.next() else { return nil }; owner = v
            case "--home": guard let v = it.next() else { return nil }; home = v
            default: return nil
            }
        }
        guard let mailbox else { return nil }
        return Options(mailbox: mailbox, owner: owner, home: home)
    }

    public static func main() -> Never {
        guard let opts = parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        var env = ProcessInfo.processInfo.environment
        if let home = opts.home { env["AGENTRELAY_HOME"] = home }
        switch Waiter(paths: RelayPaths.resolve(environment: env), mailbox: opts.mailbox, owner: opts.owner).wait() {
        case .newMail(let n):
            print(Waiter.message(for: n))
            exit(0)
        case .notOwner:
            print(Waiter.notOwnerMessage(mailbox: opts.mailbox))
            exit(3)
        case .invalid(let why):
            print("等信没法开始：\(why)")
            exit(2)
        }
    }
}
