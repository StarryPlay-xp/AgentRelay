import Foundation
import Testing
@testable import RelayCore

@Suite("本机通话口、进程信息、codex 程序调用")
struct SocketTests {
    @Test("进程信息：能读到自己的路径、父进程和启动参数")
    func processes() {
        let me = getpid()
        #expect(Processes.executablePath(me) != nil)
        #expect(Processes.parent(of: me) == getppid())
        #expect(Processes.owner(of: me) == getuid())
        #expect(Processes.arguments(of: me)?.isEmpty == false)
        #expect(Processes.allPIDs().contains(me))
    }

    @Test("父进程签名：测试进程的父进程不是 Codex 或 Claude Code")
    func signature() {
        #expect(PeerCheck.signedHost(pid: getppid()) == nil)
    }

    func server(_ policy: PeerPolicy) throws -> (SocketServer, RelayPaths, TempDir, Box<[String]>) {
        let t = try TempDir()
        let paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": t.path + "/h"])
        let rejects = Box<[String]>([])
        let s = SocketServer(paths: paths, policy: policy, onReject: { m in rejects.update { $0.append(m) } }) { req, peer in
            var r = WireResult(text: "收到 \(req.op.rawValue)")
            r.mailbox = peer.platform?.rawValue ?? "放宽"
            return .success(r)
        }
        try s.start()
        return (s, paths, t, rejects)
    }

    @Test("放宽模式：一问一答；暗号文件和套接字都是 0600")
    func roundTrip() throws {
        let (s, paths, t, _) = try server(.relaxed)
        defer { s.stop(); withExtendedLifetime(t) {} }
        let r = SocketClient.send(op: .status, caller: CallerInfo(cwd: "/"), args: WireArgs(), paths: paths)
        #expect(r.ok)
        #expect(r.result?.text == "收到 status")
        #expect(r.result?.mailbox == "放宽")
        for f in [paths.token, paths.socket] {
            let attrs = try FileManager.default.attributesOfItem(atPath: f)
            #expect((attrs[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test("暗号不对、版本不对都被拒绝")
    func badTokenAndVersion() throws {
        let (s, paths, t, rejects) = try server(.relaxed)
        defer { s.stop(); withExtendedLifetime(t) {} }
        let bad = try SocketClient.exchange(WireRequest(token: "不对", op: .status, caller: CallerInfo(cwd: "/")), socketPath: paths.socket, timeout: 5)
        #expect(bad.error?.code == .identityMismatch)
        #expect(rejects.get().count == 1)
        let token = try String(contentsOfFile: paths.token, encoding: .utf8)
        let old = try SocketClient.exchange(WireRequest(v: 99, token: token, op: .status, caller: CallerInfo(cwd: "/")), socketPath: paths.socket, timeout: 5)
        #expect(old.error?.code == .versionMismatch)
    }

    @Test("正式模式：不是 relay-mcp 的进程连进来被拒绝")
    func strictRejects() throws {
        let (s, paths, t, rejects) = try server(.strict(relayMCP: "/private/tmp/不存在/relay-mcp"))
        defer { s.stop(); withExtendedLifetime(t) {} }
        let r = SocketClient.send(op: .status, caller: CallerInfo(cwd: "/"), args: WireArgs(), paths: paths)
        #expect(r.error?.code == .identityMismatch)
        #expect(rejects.get().count == 1)
    }

    @Test("对端程序和操作：relay-hook 只能上报钩子事件，relay-mcp 不能冒充钩子")
    func peerOps() {
        let hook = VerifiedPeer(platform: .codex, program: .relayHook, hostPID: 1)
        let mcp = VerifiedPeer(platform: .codex, program: .relayMCP, hostPID: 1)
        #expect(hook.allows(.hook))
        for op in [WireOp.register, .contacts, .send, .inbox, .status] {
            #expect(!hook.allows(op))
            #expect(mcp.allows(op))
            #expect(VerifiedPeer.relaxed.allows(op))
        }
        #expect(!mcp.allows(.hook))
        #expect(VerifiedPeer.relaxed.allows(.hook))
    }

    @Test("中转核心没运行：RELAY_NOT_RUNNING")
    func notRunning() throws {
        let t = try TempDir()
        let paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": t.path + "/h"])
        #expect(SocketClient.send(op: .status, caller: CallerInfo(cwd: "/"), args: WireArgs(), paths: paths).error?.code == .relayNotRunning)
        try paths.prepare()
        try FileSystem.writeAtomically(Data("abc".utf8), to: paths.token)
        #expect(SocketClient.send(op: .status, caller: CallerInfo(cwd: "/"), args: WireArgs(), paths: paths).error?.code == .relayNotRunning)
    }

    @Test("单实例锁：同一位置只能有一个中转核心")
    func instanceLock() throws {
        let t = try TempDir()
        let first = try InstanceLock(path: t.path + "/lock")
        #expect(throws: RelayError.self) { try InstanceLock(path: t.path + "/lock") }
        _ = first
    }

    @Test("调用 codex 程序：用假脚本，参数正确、不带 --resume，解析排队编号；失败和找不到程序")
    func codexCLI() throws {
        let t = try TempDir()
        let log = t.path + "/args.txt"
        let script = t.path + "/codex"
        try """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a" >> "\(log)"; done
        if [ "$3" = "失败" ]; then echo "boom" >&2; exit 3; fi
        echo "Queued message \(sampleID(98)) for thread $3."
        """.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let cli = CodexCLI(timeout: 5, executable: { script })
        #expect(cli.enqueue(threadID: sampleID(1), message: "多行\n信") == .queued(ref: sampleID(98)))
        let args = try String(contentsOfFile: log, encoding: .utf8)
        #expect(args.hasPrefix("queue\n--thread\n\(sampleID(1))\n--message\n多行\n信\n"))
        #expect(!args.contains("--resume"))
        if case .failed(let why) = cli.enqueue(threadID: "失败", message: "x") { #expect(why.contains("退出码 3")) } else { Issue.record("应当失败") }
        #expect(CodexCLI(timeout: 5, executable: { nil }).enqueue(threadID: "x", message: "y") == .unavailable("找不到 codex 程序（ChatGPT 桌面版没装，或者路径不对）"))
        #expect(CodexCLI.parseQueueRef("没有编号") == nil)
    }

    @Test("同一收件会话串行、不同会话并行")
    func dispatcherOrdering() throws {
        final class Slow: CodexQueueing, @unchecked Sendable {
            let log = Box<[String]>([])
            func enqueue(threadID: String, message: String) -> CodexQueueOutcome {
                log.update { $0.append("开始 \(message)") }
                usleep(50_000)
                log.update { $0.append("结束 \(message)") }
                return .queued(ref: nil)
            }
        }
        let slow = Slow()
        let d = CodexDispatcher(queuer: slow, retryDelays: [])
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            _ = d.deliver(messageID: "m\(i)", threadID: "同一个", text: "a\(i)") { _, _, _ in }
        }
        let log = slow.log.get()
        #expect(log.count == 4)
        #expect(log[0].hasPrefix("开始") && log[1].hasPrefix("结束"), "同一会话不交错：\(log)")
    }

    @Test("Claude 信箱标记：写未读数，读完删除")
    func mailboxMarker() throws {
        let t = try TempDir()
        let paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": t.path + "/h"])
        try paths.prepare()
        let box = ClaudeMailbox(paths: paths)
        try box.setUnread(2, mailbox: "claude-1")
        #expect(box.unreadMarker(mailbox: "claude-1") == 2)
        try box.setUnread(0, mailbox: "claude-1")
        #expect(box.unreadMarker(mailbox: "claude-1") == nil)
    }
}
