import Darwin
import Foundation
import Security

/// 连进本机通话口的对端进程
public struct PeerInfo: Sendable, Equatable {
    public let pid: pid_t
    public let uid: uid_t
    public let executable: String?
    public let parentPID: pid_t?
    public let parentExecutable: String?
}

/// 防冒充（设计方案第 15 节）：对端必须是同一用户的 relay-mcp，
/// 而且 relay-mcp 必须是由带厂商签名的 Codex 或 Claude Code 拉起的。
/// 这样会话不能在自己的终端里手动运行 relay-mcp、编造调用方信息去冒充别的会话。
/// relay-hook（和 relay-mcp 在同一个 bin 目录）由 Codex 经登录 shell 拉起，往上几层里要有带签名的 Codex。
public enum PeerPolicy: Sendable, Equatable {
    /// 正式模式：核对用户、relay-mcp 的路径、父进程签名；平台由签名决定
    case strict(relayMCP: String)
    /// 开发和测试：只核对用户，平台从调用方信息推断
    case relaxed
}

/// 连进来的是哪个程序
public enum PeerProgram: String, Sendable, Equatable {
    case relayMCP = "relay-mcp"
    case relayHook = "relay-hook"
}

/// 核对通过的对端
public struct VerifiedPeer: Sendable, Equatable {
    /// 按签名认出的平台；放宽检查时为 nil
    public let platform: Platform?
    /// 认出的程序；放宽检查时为 nil
    public let program: PeerProgram?
    /// 拉起它的 Codex 或 Claude Code 进程号（relay-hook 是往上找到的 Codex 后台服务）；放宽检查时为 nil
    public let hostPID: pid_t?

    public init(platform: Platform?, program: PeerProgram?, hostPID: pid_t?) {
        self.platform = platform
        self.program = program
        self.hostPID = hostPID
    }

    /// 放宽检查（开发、测试）
    public static let relaxed = VerifiedPeer(platform: nil, program: nil, hostPID: nil)

    /// 这个对端能不能调用这项操作：relay-hook 只能上报钩子事件，relay-mcp 不能冒充钩子
    public func allows(_ op: WireOp) -> Bool {
        switch program {
        case .relayHook: return op == .hook
        case .relayMCP: return op != .hook
        case nil: return true
        }
    }
}

public enum PeerCheck {
    /// 宿主程序的签名要求：开发者团队编号是公开信息（`codesign -dv` 可见）
    static let hosts: [(platform: Platform, requirement: String)] = [
        (.codex, #"identifier "codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#),
        (.claude, #"identifier "com.anthropic.claude-code" and anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#),
    ]

    /// 读出套接字对端的进程信息
    public static func peer(of fd: Int32) throws -> PeerInfo {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw RelayError(.identityMismatch, "读不到对端用户")
        }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else {
            throw RelayError(.identityMismatch, "读不到对端进程")
        }
        let ppid = Processes.parent(of: pid)
        return PeerInfo(pid: pid, uid: uid, executable: Processes.executablePath(pid),
                        parentPID: ppid, parentExecutable: ppid.flatMap(Processes.executablePath))
    }

    /// relay-hook 往上最多找几层（Codex 用 `$SHELL -lc` 运行钩子命令，shell 可能直接换成 relay-hook，也可能再起一层）
    static let hookAncestorDepth = 3

    /// 按策略核对对端；正式模式下返回按签名认出的平台和程序
    public static func verify(_ peer: PeerInfo, policy: PeerPolicy) throws -> VerifiedPeer {
        guard peer.uid == getuid() else {
            throw RelayError(.identityMismatch, "对端不是当前用户的进程")
        }
        guard case .strict(let relayMCP) = policy else { return .relaxed }
        let relayHook = (relayMCP as NSString).deletingLastPathComponent + "/relay-hook"
        let exe = peer.executable.map(PathMatcher.normalize)
        if exe == PathMatcher.normalize(relayMCP) {
            guard let ppid = peer.parentPID, let platform = signedHost(pid: ppid) else {
                throw RelayError(.identityMismatch, "relay-mcp 不是由 Codex 或 Claude Code 启动的（例如在终端里手动运行）")
            }
            return VerifiedPeer(platform: platform, program: .relayMCP, hostPID: ppid)
        }
        if exe == PathMatcher.normalize(relayHook) {
            var pid = peer.parentPID
            for _ in 0..<hookAncestorDepth {
                guard let p = pid, p > 1 else { break }
                if signedHost(pid: p) == .codex { return VerifiedPeer(platform: .codex, program: .relayHook, hostPID: p) }
                pid = Processes.parent(of: p)
            }
            throw RelayError(.identityMismatch, "relay-hook 不是由 Codex 的钩子启动的（例如在终端里手动运行）")
        }
        throw RelayError(.identityMismatch, "连进来的不是 AgentRelay 的 relay-mcp 或 relay-hook")
    }

    /// 按进程号核对签名，认出是 Codex 还是 Claude Code
    public static func signedHost(pid: pid_t) -> Platform? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        for host in hosts {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(host.requirement as CFString, [], &req) == errSecSuccess, let req else { continue }
            if SecCodeCheckValidity(code, [], req) == errSecSuccess { return host.platform }
        }
        return nil
    }
}
