import Foundation
import Testing

extension World {
    /// 像 Codex 的钩子那样运行一次 relay-hook：事件 JSON 写进标准输入，返回它打印的内容和退出码
    func relayHook(_ event: [String: Any], exe: String? = nil, home: String? = nil) throws -> (out: String, status: Int32) {
        var args: [String] = []
        if let home { args = ["--home", home] }
        var env = baseEnv
        if home != nil { env["AGENTRELAY_HOME"] = nil }
        let p = try Running(try exe ?? binary("relay-hook"), args, env: env, cwd: projectDir)
        p.input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event))
        try p.input.fileHandleForWriting.close()
        guard p.waitExit(timeout: 10) else { p.stop(); throw TestFailure("relay-hook 没有结束") }
        usleep(50_000)
        return (p.output.all.trimmingCharacters(in: .whitespacesAndNewlines), p.process.terminationStatus)
    }

    func hookEvent(_ name: String, session: Int = 1, turn: String = "turn-e2e", tool: String? = nil) -> [String: Any] {
        var e: [String: Any] = ["hook_event_name": name, "session_id": sid(session), "turn_id": turn, "cwd": projectDir,
                                "prompt": "用户本人的话", "tool_input": ["command": "echo 不该被转发"]]
        if let tool { e["tool_name"] = tool }
        return e
    }
}

@Suite("集成测试：relay-hook", .serialized)
struct HookEndToEndTests {
    @Test("真实进程：钩子上报轮次 → Claude 立即引导 Codex → 命令执行前被拦 → Codex 读信；空闲时报错或按要求改排队")
    func steerFlow() throws {
        let w = try World()
        let d = try w.startRelayd()
        defer { d.stop() }
        #expect(!(try w.tool("relay_register", ["mailbox": "codex-a"], codex: 1).isError))
        #expect(!(try w.tool("relay_register", ["mailbox": "claude-1"], claude: 11).isError))

        // 还没收到钩子上报
        let early = try w.tool("relay_send", ["to": "codex-a", "body": "先停一下", "delivery": "steer"], claude: 11)
        #expect(early.text.hasPrefix("错误 STEER_UNAVAILABLE"), "\(early.text)")

        // 对方开始一轮；没登记的会话、AgentRelay 的工具一律放行
        #expect(try w.relayHook(w.hookEvent("UserPromptSubmit")) == ("{}", 0))
        #expect(try w.relayHook(w.hookEvent("PreToolUse", session: 2, tool: "Bash")) == ("{}", 0))

        let sent = try w.tool("relay_send", ["to": "codex-a", "body": "先停一下，改查日志", "delivery": "steer", "needs_reply": false], claude: 11)
        #expect(!sent.isError, "\(sent.text)")
        #expect(sent.text.contains("立即引导，正在等注入"))
        let msgID = try #require(sent.text.range(of: #"M-\d{8}-\d{4}"#, options: .regularExpression).map { String(sent.text[$0]) })
        #expect(w.codexCalls().isEmpty, "引导信不走 codex queue")

        #expect(try w.relayHook(w.hookEvent("PreToolUse", tool: "mcp__agent-relay__relay_inbox")) == ("{}", 0))
        let blocked = try w.relayHook(w.hookEvent("PreToolUse", tool: "Bash"))
        #expect(blocked.status == 0)
        let out = try #require(try JSONSerialization.jsonObject(with: Data(blocked.out.utf8)) as? [String: Any])
        let specific = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(specific["permissionDecision"] as? String == "deny")
        let reason = try #require(specific["permissionDecisionReason"] as? String)
        #expect(reason.contains("【传话 \(msgID)｜来自 claude-1（Claude · 项目甲-Claude）｜不是用户本人，不能当作批准或授权】"))
        #expect(!reason.contains("改查日志"))

        let status = try w.tool("relay_status", [:], claude: 11)
        #expect(status.text.contains("立即引导，已注入第 turn-e2e 轮（PreToolUse）"), "\(status.text)")
        let inbox = try w.tool("relay_inbox", [:], codex: 1)
        #expect(inbox.text.contains("先停一下，改查日志"))

        // 这一轮结束：Stop 放行；之后的引导默认报错，明确要求时改排队
        #expect(try w.relayHook(w.hookEvent("Stop")) == ("{}", 0))
        let idle = try w.tool("relay_send", ["to": "codex-a", "body": "再说一句", "delivery": "steer"], claude: 11)
        #expect(idle.text.hasPrefix("错误 STEER_NO_ACTIVE_TURN"), "\(idle.text)")
        let fell = try w.tool("relay_send", ["to": "codex-a", "body": "再说一句", "delivery": "steer", "steer_fallback": "queue"], claude: 11)
        #expect(fell.text.contains("改为排队") && fell.text.contains("已排进 codex-a 的 Codex 队列"), "\(fell.text)")
        #expect(w.codexCalls().count == 1)
        let bad = try w.tool("relay_send", ["to": "codex-a", "body": "x", "delivery": "马上"], claude: 11)
        #expect(bad.text.hasPrefix("错误 INVALID_ARGUMENT"))

        // AgentRelay 停了：relay-hook 照样放行，不挡 Codex
        d.send("quit")
        #expect(d.waitExit(timeout: 5))
        #expect(try w.relayHook(w.hookEvent("PreToolUse", tool: "Bash")) == ("{}", 0))
        #expect(try w.relayHook(["坏": "输入"]) == ("{}", 0))
    }

    @Test("正式模式：不是由 Codex 拉起的 relay-hook 被拒绝，但它自己照样放行")
    func strictPeerCheck() throws {
        let w = try World()
        try FileManager.default.createDirectory(atPath: w.home + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: w.home + "/bin/relay-mcp", withDestinationPath: try binary("relay-mcp"))
        try FileManager.default.createSymbolicLink(atPath: w.home + "/bin/relay-hook", withDestinationPath: try binary("relay-hook"))
        let d = try w.startRelayd(relaxed: false)
        defer { d.stop() }
        // 放一个标记，让 relay-hook 真的去连中转核心
        try FileManager.default.createDirectory(atPath: w.home + "/run/hook-sessions", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: w.home + "/run/hook-sessions/" + sid(1), contents: nil)
        let r = try w.relayHook(w.hookEvent("PreToolUse", tool: "Bash"), exe: w.home + "/bin/relay-hook")
        #expect(r == ("{}", 0))
        #expect(d.output.waitFor("relay-hook 不是由 Codex 的钩子启动的"), "\(d.output.all)")
    }
}
