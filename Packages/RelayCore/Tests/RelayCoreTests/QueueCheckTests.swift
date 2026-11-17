import Foundation
import Testing
@testable import RelayCore

/// 假的核对：按预设回答“找到 / 没有 / 查不了”，记下被问过几次
final class FakeChecker: CodexQueueChecking, @unchecked Sendable {
    let answer: Bool?
    let asked = Box(0)
    init(_ answer: Bool?) { self.answer = answer }
    func contains(threadID: String, messageID: String) -> Bool? {
        asked.update { $0 += 1 }
        return answer
    }
}

@Suite("排队：结果未知时核对、不盲目重试")
struct QueueCheckTests {
    func deliver(_ outcomes: [CodexQueueOutcome], checker: CodexQueueChecking?) -> (CodexQueueOutcome, FakeCodex, Box<[(CodexQueueOutcome, Bool)]>) {
        let codex = FakeCodex()
        codex.script(outcomes)
        let d = CodexDispatcher(queuer: codex, checker: checker, retryDelays: [0.01, 0.01, 0.01])
        let reports = Box<[(CodexQueueOutcome, Bool)]>([])
        let first = d.deliver(messageID: "M-20261117-0001", threadID: sampleID(1), text: "信") { _, o, final in
            reports.update { $0.append((o, final)) }
        }
        return (first, codex, reports)
    }

    func waitFinal(_ reports: Box<[(CodexQueueOutcome, Bool)]>) {
        let deadline = Date().addingTimeInterval(3)
        while !(reports.get().last?.1 ?? false) && Date() < deadline { usleep(10_000) }
    }

    @Test("超时后核对找到了：算已排队，不再排第二次")
    func checkedFound() {
        let checker = FakeChecker(true)
        let (first, codex, reports) = deliver([.unknown("codex queue 30 秒没有结束")], checker: checker)
        #expect(first == .queued(ref: nil))
        #expect(codex.count == 1)
        #expect(checker.asked.get() == 1)
        #expect(reports.get().last?.1 == true)
    }

    @Test("超时后核对确认没有：当作失败，照常重试")
    func checkedMissing() {
        let (first, codex, reports) = deliver([.unknown("codex queue 30 秒没有结束"), .queued(ref: "q")], checker: FakeChecker(false))
        if case .failed(let why) = first { #expect(why.contains("核对后确认没有排进去")) } else { Issue.record("应当当作失败：\(first)") }
        waitFinal(reports)
        #expect(codex.count == 2)
        #expect(reports.get().last?.0 == .queued(ref: "q"))
    }

    @Test("超时后查不了（或没有核对器）：停在结果未知，不重试")
    func uncheckable() {
        for checker in [FakeChecker(nil), nil] as [FakeChecker?] {
            let (first, codex, reports) = deliver([.unknown("codex queue 30 秒没有结束")], checker: checker)
            if case .unknown(let why) = first { #expect(why.contains("也没能核对")) } else { Issue.record("应当结果未知：\(first)") }
            usleep(100_000)
            #expect(codex.count == 1, "不重试")
            #expect(reports.get().count == 1 && reports.get()[0].1)
        }
    }

    @Test("中转服务：结果未知时状态为“结果未知”，通知用户，回执说明没有重试")
    func serviceUnknown() throws {
        let h = try Harness()
        h.registerAll()
        h.codex.script([.unknown("codex queue 30 秒没有结束")])
        let r = h.ok(h.codex(1), .send, WireArgs(to: "codex-b", body: "x"))
        #expect(r.delivery == .unknown)
        #expect(r.text.contains("投递结果未知"))
        h.waitFor { (try? h.service.store.message(id: r.messageID!))?.status == .unknown }
        #expect(try h.service.store.message(id: r.messageID!)?.status == .unknown)
        #expect(h.notices.get().contains { $0.kind == "结果未知" })
        #expect(h.codex.count == 1)
    }

    @Test("codex queue：超时报结果未知；本机有共享后台服务时报不可用、不重试")
    func cliOutcomes() throws {
        let t = try TempDir()
        let script = t.path + "/codex"
        try """
        #!/bin/sh
        if [ "$3" = "慢" ]; then sleep 5; fi
        if [ "$3" = "守护" ]; then echo "Error: cannot queue through an embedded app server while a local app-server daemon is running; remove configuration overrides or use --remote" >&2; exit 1; fi
        echo "Queued message q1 for thread $3."
        """.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let cli = CodexCLI(timeout: 1, executable: { script })
        if case .unknown(let why) = cli.enqueue(threadID: "慢", message: "x") { #expect(why.contains("没有结束")) } else { Issue.record("超时应当是结果未知") }
        if case .unavailable(let why) = cli.enqueue(threadID: "守护", message: "x") { #expect(why.contains("共享后台服务")) } else { Issue.record("应当不可用") }
        #expect(cli.enqueue(threadID: "正常", message: "x") == .queued(ref: "q1"))
    }

    /// 假的 `codex app-server`：一行一条 JSON-RPC；排队里放 `QUEUED`，最近一轮的用户消息放 `HISTORY`
    func fakeAppServer(_ dir: String) throws -> String {
        let path = dir + "/codex"
        try #"""
        #!/bin/sh
        [ "$1" = "app-server" ] || exit 2
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake"}}\n' "$id" ;;
            *'"method":"initialized"'*) printf '{"method":"thread/started","params":{}}\n' ;;
            *'"method":"thread/queue/list"'*)
              [ -n "$FAIL" ] && { printf '{"id":%s,"error":{"code":-32600,"message":"no"}}\n' "$id"; continue; }
              printf '{"id":%s,"result":{"data":[{"id":"q","input":[{"type":"text","text":"%s"}],"clientUserMessageId":"c"}],"nextCursor":null}}\n' "$id" "$QUEUED" ;;
            *'"method":"thread/turns/list"'*)
              printf '{"id":%s,"result":{"data":[{"id":"t","items":[{"type":"userMessage","content":[{"type":"text","text":"%s"}]}]}],"nextCursor":null}}\n' "$id" "$HISTORY" ;;
          esac
        done
        """#.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    /// 手动开启：scripts/codex-steer-probe/queue_check_probe.py 在隔离的 CODEX_HOME 里准备好会话后，带着环境变量运行这一项
    @Test("真的 codex：在隔离的 CODEX_HOME 里核对排队和历史（手动开启）",
          .enabled(if: ProcessInfo.processInfo.environment["AGENTRELAY_REAL_QUEUE_CHECK"] != nil))
    func realCodex() throws {
        let env = ProcessInfo.processInfo.environment
        let exe = try #require(env["CODEX_BIN"]), home = try #require(env["CODEX_HOME"]), thread = try #require(env["CHECK_THREAD"])
        #expect(home.hasPrefix("/tmp/") || home.hasPrefix("/private/tmp/"), "只对临时目录里的隔离环境运行")
        let checker = CodexAppServerQueueChecker(codexHome: home, executable: { exe })
        #expect(checker.contains(threadID: thread, messageID: try #require(env["CHECK_IN_HISTORY"])) == true)
        #expect(checker.contains(threadID: thread, messageID: try #require(env["CHECK_IN_QUEUE"])) == true)
        #expect(checker.contains(threadID: thread, messageID: try #require(env["CHECK_MISSING"])) == false)
    }

    @Test("核对器：在排队或最近的用户消息里按信封开头找；出错、有共享后台服务时算查不了")
    func appServerChecker() throws {
        let t = try TempDir()
        let fake = try fakeAppServer(t.path)
        let id = "M-20261117-0007"
        let head = Envelope.headlinePrefix(messageID: id) + "来自 codex-b"
        func check(queued: String = "", history: String = "", fail: Bool = false, home: String? = nil) -> Bool? {
            setenv("QUEUED", queued, 1)
            setenv("HISTORY", history, 1)
            if fail { setenv("FAIL", "1", 1) } else { unsetenv("FAIL") }
            defer { unsetenv("QUEUED"); unsetenv("HISTORY"); unsetenv("FAIL") }
            return CodexAppServerQueueChecker(codexHome: home ?? t.path + "/cx", timeout: 5, executable: { fake })
                .contains(threadID: sampleID(1), messageID: id)
        }
        #expect(check(queued: head) == true)
        #expect(check(history: head) == true)
        #expect(check(queued: "【传话 M-20261117-0070｜别的信", history: "回信：reply_to=\\\"\(id)\\\"") == false, "只认信封开头，不认正文里提到的编号")
        #expect(check(fail: true) == nil)
        // 本机有共享后台服务：不另起服务
        let daemonHome = t.path + "/daemon"
        try FileManager.default.createDirectory(atPath: daemonHome + "/app-server-control", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: daemonHome + "/app-server-control/app-server-control.sock", contents: nil)
        #expect(check(queued: head, home: daemonHome) == nil)
        #expect(CodexAppServerQueueChecker(codexHome: t.path, executable: { nil }).contains(threadID: sampleID(1), messageID: id) == nil)
    }
}
