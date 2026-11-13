import Foundation

/// relay-wait 的逻辑（设计方案第 5.3 节）：盯着信箱目录里的“有新信”标记，出现就打印一句提示并结束，
/// Claude 会话因后台命令结束而被叫醒。只看标记里的未读数，不读信件内容；不设时间上限（F13）。
public struct Waiter: Sendable {
    public let paths: RelayPaths
    public let mailbox: String
    public let interval: TimeInterval

    public init(paths: RelayPaths, mailbox: String, interval: TimeInterval = 1) {
        self.paths = paths
        self.mailbox = mailbox
        self.interval = interval
    }

    public enum Outcome: Equatable, Sendable {
        /// 有新信
        case newMail(Int)
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

    /// 一直等到有新信
    public func wait() -> Outcome {
        do { try check() } catch let e as RelayError { return .invalid(e.message) } catch { return .invalid("\(error)") }
        let box = ClaudeMailbox(paths: paths)
        while true {
            if let n = box.unreadMarker(mailbox: mailbox), n > 0 { return .newMail(n) }
            // AgentRelay 被卸载（运行目录被删）后不再空等
            if !FileManager.default.fileExists(atPath: paths.run) {
                return .invalid("AgentRelay 的运行目录不见了（可能已卸载），停止等信")
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    public static func message(for n: Int) -> String {
        "你有 \(n) 封新信，请调用 relay_inbox 读取；读完后再重新在后台运行等信命令。"
    }
}

/// relay-wait 命令行入口（包里的 relay-wait 和应用内嵌的 relay-wait 都调用它）。
/// 用法：relay-wait --mailbox <信箱名> [--home <AGENTRELAY_HOME>]
/// 有新信时打印一句提示并以 0 退出；参数或环境不对以 2 退出。
public enum RelayWaitCommand {
    public static let usage = "用法：relay-wait --mailbox <信箱名> [--home <目录>]"

    public struct Options: Equatable, Sendable {
        public var mailbox: String
        public var home: String?
    }

    /// 解析参数（不含程序名）；不合法时返回 nil
    public static func parse(_ arguments: [String]) -> Options? {
        var mailbox: String?
        var home: String?
        var it = arguments.makeIterator()
        while let a = it.next() {
            switch a {
            case "--mailbox": guard let v = it.next() else { return nil }; mailbox = v
            case "--home": guard let v = it.next() else { return nil }; home = v
            default: return nil
            }
        }
        guard let mailbox else { return nil }
        return Options(mailbox: mailbox, home: home)
    }

    public static func main() -> Never {
        guard let opts = parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        var env = ProcessInfo.processInfo.environment
        if let home = opts.home { env["AGENTRELAY_HOME"] = home }
        switch Waiter(paths: RelayPaths.resolve(environment: env), mailbox: opts.mailbox).wait() {
        case .newMail(let n):
            print(Waiter.message(for: n))
            exit(0)
        case .invalid(let why):
            print("等信没法开始：\(why)")
            exit(2)
        }
    }
}
