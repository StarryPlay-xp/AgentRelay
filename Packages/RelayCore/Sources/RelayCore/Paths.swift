import Darwin
import Foundation

/// AgentRelay 自己用到的所有位置（设计方案第 6 节）。
///
/// - 默认：运行时文件在 `~/.agentrelay/`，数据在 `~/Library/Application Support/AgentRelay/`，
///   日志在 `~/Library/Logs/AgentRelay/`。
/// - 设置了 `AGENTRELAY_HOME` 时，全部放到这个目录下（`data/`、`logs/` 子目录），用于测试和开发，
///   不会碰到正式数据。
public struct RelayPaths: Sendable, Equatable {
    /// `~/.agentrelay` 或 `AGENTRELAY_HOME`
    public let home: String
    /// 数据目录：数据库、登记表、备份
    public let data: String
    /// 日志目录（日志里不写信件正文）
    public let logs: String

    public var bin: String { home + "/bin" }
    public var run: String { home + "/run" }
    public var socket: String { run + "/relay.sock" }
    public var token: String { run + "/token" }
    public var lock: String { run + "/relayd.lock" }
    public var mailboxes: String { run + "/mailboxes" }
    public var database: String { data + "/relay.sqlite" }
    public var registry: String { data + "/registry.json" }
    public var backups: String { data + "/backups" }

    /// 收件信箱的“有新信”标记目录：`run/mailboxes/<信箱名>/`
    public func mailbox(_ name: String) -> String { mailboxes + "/" + name }
    /// 标记文件，内容是未读数
    public func mailboxMarker(_ name: String) -> String { mailbox(name) + "/new" }

    /// 套接字路径的上限：`sockaddr_un.sun_path` 是 104 字节，含结尾的 0。
    public static let maxSocketPathBytes = 103

    public init(home: String, data: String, logs: String) {
        self.home = home
        self.data = data
        self.logs = logs
    }

    /// 按环境变量决定位置。`AGENTRELAY_HOME` 为空或没设时用默认位置。
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: String = RelayPaths.userHome()
    ) -> RelayPaths {
        if let custom = environment["AGENTRELAY_HOME"], !custom.isEmpty {
            let home = expandTilde(custom, userHome: userHome)
            return RelayPaths(home: home, data: home + "/data", logs: home + "/logs")
        }
        return RelayPaths(
            home: userHome + "/.agentrelay",
            data: userHome + "/Library/Application Support/AgentRelay",
            logs: userHome + "/Library/Logs/AgentRelay"
        )
    }

    /// 当前用户的家目录，取自系统用户数据库，不依赖 `HOME` 环境变量。
    public static func userHome() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func expandTilde(_ path: String, userHome: String) -> String {
        if path == "~" { return userHome }
        if path.hasPrefix("~/") { return userHome + path.dropFirst(1) }
        return path
    }

    /// 建好运行时目录和数据目录，并收紧权限：目录 0700。
    public func prepare() throws {
        for dir in [home, bin, run, mailboxes, data, backups, logs] {
            try FileSystem.makeDirectory(dir, mode: 0o700)
        }
        guard socket.utf8.count <= RelayPaths.maxSocketPathBytes else {
            throw RelayError(.internalError, "本机通话口路径太长（超过 \(RelayPaths.maxSocketPathBytes) 字节），请换一个更短的 AGENTRELAY_HOME")
        }
    }
}

/// Codex、Claude 的本机数据位置（只读）。测试时换成合成目录。
public struct ExternalPaths: Sendable, Equatable {
    /// Codex 会话记录：`~/.codex/sessions`
    public let codexSessions: String
    /// Claude 会话记录：`~/.claude/projects`
    public let claudeProjects: String

    public init(codexSessions: String, claudeProjects: String) {
        self.codexSessions = codexSessions
        self.claudeProjects = claudeProjects
    }

    /// 默认位置；`CODEX_HOME`、`CLAUDE_CONFIG_DIR` 有值时按它们来。
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: String = RelayPaths.userHome()
    ) -> ExternalPaths {
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome + "/.codex"
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome + "/.claude"
        return ExternalPaths(
            codexSessions: RelayPaths.expandTilde(codexHome, userHome: userHome) + "/sessions",
            claudeProjects: RelayPaths.expandTilde(claudeHome, userHome: userHome) + "/projects"
        )
    }
}

/// 少量文件操作的封装，统一处理权限。
public enum FileSystem {
    /// 建目录（含上级），并把这一级设成指定权限。
    public static func makeDirectory(_ path: String, mode: mode_t) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw RelayError(.internalError, "应当是目录，却是文件：\(path)")
            }
        } else {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        if chmod(path, mode) != 0 {
            throw RelayError(.internalError, "无法设置目录权限：\(path)（\(String(cString: strerror(errno)))）")
        }
    }

    /// 原子写入：先写同目录下的临时文件，再改名覆盖，权限 0600。
    public static func writeAtomically(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/.tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else {
            throw RelayError(.internalError, "无法写入：\(path)（\(String(cString: strerror(errno)))）")
        }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            unlink(tmp)
            throw RelayError(.internalError, "无法写入：\(path)")
        }
    }
}
