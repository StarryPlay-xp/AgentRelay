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
public enum PeerPolicy: Sendable, Equatable {
    /// 正式模式：核对用户、relay-mcp 的路径、父进程签名；平台由签名决定
    case strict(relayMCP: String)
    /// 开发和测试：只核对用户，平台从调用方信息推断
    case relaxed
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

    /// 按策略核对对端；正式模式下返回按签名认出的平台
    public static func verify(_ peer: PeerInfo, policy: PeerPolicy) throws -> Platform? {
        guard peer.uid == getuid() else {
            throw RelayError(.identityMismatch, "对端不是当前用户的进程")
        }
        guard case .strict(let relayMCP) = policy else { return nil }
        let expected = PathMatcher.normalize(relayMCP)
        guard let exe = peer.executable, PathMatcher.normalize(exe) == expected else {
            throw RelayError(.identityMismatch, "连进来的不是 AgentRelay 的 relay-mcp")
        }
        guard let ppid = peer.parentPID, let platform = signedHost(pid: ppid) else {
            throw RelayError(.identityMismatch, "relay-mcp 不是由 Codex 或 Claude Code 启动的（例如在终端里手动运行）")
        }
        return platform
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
