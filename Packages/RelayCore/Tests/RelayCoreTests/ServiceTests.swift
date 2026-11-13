import Foundation
import Testing
@testable import RelayCore

/// 假的 Codex 排队：记录收到的信，按预设返回结果。不调用任何真实程序。
final class FakeCodex: CodexQueueing, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [CodexQueueOutcome] = []
    private(set) var sent: [(thread: String, text: String)] = []

    func script(_ o: [CodexQueueOutcome]) { lock.lock(); outcomes = o; lock.unlock() }

    func enqueue(threadID: String, message: String) -> CodexQueueOutcome {
        lock.lock()
        defer { lock.unlock() }
        sent.append((threadID, message))
        return outcomes.isEmpty ? .queued(ref: sampleID(99)) : outcomes.removeFirst()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return sent.count }
    var last: (thread: String, text: String)? { lock.lock(); defer { lock.unlock() }; return sent.last }
}

final class FakeWaits: WaitDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Set<String> = []
    func set(_ m: String, _ on: Bool) { lock.lock(); if on { waiting.insert(m) } else { waiting.remove(m) }; lock.unlock() }
    func isWaiting(mailbox: String) -> Bool { lock.lock(); defer { lock.unlock() }; return waiting.contains(mailbox) }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

/// 一套完整的测试环境：临时 AGENTRELAY_HOME、合成会话记录、登记表、假 Codex
final class Harness: @unchecked Sendable {
    let fx: RecordFixture
    let paths: RelayPaths
    let codex = FakeCodex()
    let waits = FakeWaits()
    let now = Box(Date())
    let notices = Box<[Notice]>([])
    let appServer = Box<pid_t?>(100)
    var service: RelayService!
    let dirA: String, dirB: String, dirOther: String

    init(limits: Limits = Limits(), retryDelays: [TimeInterval] = [0.01, 0.01, 0.01]) throws {
        fx = try RecordFixture()
        paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": fx.root.path + "/h"])
        try paths.prepare()
        dirA = fx.root.path + "/项目甲"
        dirB = fx.root.path + "/项目乙"
        dirOther = fx.root.path + "/别组"
        for d in [dirA, dirB, dirOther] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        try writeRegistry()
        let store = try Store(path: paths.database)
        service = RelayService(
            paths: paths, store: store, registry: RegistryStore(path: paths.registry, userHome: fx.root.path),
            resolver: IdentityResolver(locator: SessionRecordLocator(paths: fx.external)), limits: limits,
            dispatcher: CodexDispatcher(queuer: codex, retryDelays: retryDelays), waits: waits,
            appServerPID: { [appServer] in appServer.get() }, clock: { [now] in now.get() },
            notify: { [notices] n in notices.update { $0.append(n) } })
        // 会话记录：1、2 是 Codex（项目甲、项目乙），11、12 是 Claude（项目甲），21 是别组 Claude
        try fx.addCodex(sampleID(1), cwd: dirA)
        try fx.addCodex(sampleID(2), cwd: dirB)
        try fx.addClaude(sampleID(11), cwd: dirA)
        try fx.addClaude(sampleID(12), cwd: dirA, dirName: "-另一个")
        try fx.addClaude(sampleID(21), cwd: dirOther, dirName: "-别组")
        try fx.addCodex(sampleID(31), cwd: fx.root.path + "/没登记")
    }

    func writeRegistry(disableB: Bool = false) throws {
        let file = RegistryFile(groups: ["组甲", "组乙"], projects: [
            .init(name: "项目甲", platform: .codex, group: "组甲", paths: [dirA]),
            .init(name: "项目乙", platform: .codex, group: "组甲", paths: [dirB], enabled: !disableB),
            .init(name: "项目甲-Claude", platform: .claude, group: "组甲", paths: [dirA]),
            .init(name: "别组-Claude", platform: .claude, group: "组乙", paths: [dirOther]),
        ])
        let data = try JSONEncoder().encode(file)
        try data.write(to: URL(fileURLWithPath: paths.registry))
        // 保证修改时间变化，让登记表重读
        var times = [timespec(tv_sec: Int(Date().timeIntervalSince1970) + Int.random(in: 1...100_000), tv_nsec: 0), timespec()]
        times[1] = times[0]
        utimensat(AT_FDCWD, paths.registry, &times, 0)
    }

    func codex(_ n: Int, cwd: String? = nil) -> (CallerInfo, Platform) {
        (CallerInfo(cwd: cwd ?? (n == 2 ? dirB : n == 31 ? fx.root.path + "/没登记" : dirA), codexThreadID: sampleID(n), clientName: "codex-mcp-client"), .codex)
    }

    func claude(_ n: Int) -> (CallerInfo, Platform) {
        (CallerInfo(cwd: n == 21 ? dirOther : dirA, claudeSessionID: sampleID(n), claudeHostSessionID: "local_示例\(n)", clientName: "claude-code"), .claude)
    }

    @discardableResult
    func call(_ who: (CallerInfo, Platform), _ op: WireOp, _ args: WireArgs = WireArgs()) -> WireResponse {
        service.handle(WireRequest(token: "", op: op, caller: who.0, args: args), peerPlatform: who.1)
    }

    func ok(_ who: (CallerInfo, Platform), _ op: WireOp, _ args: WireArgs = WireArgs(),
            sourceLocation: SourceLocation = #_sourceLocation) -> WireResult {
        let r = call(who, op, args)
        #expect(r.ok, "\(r.error?.code.rawValue ?? "")：\(r.error?.message ?? "")", sourceLocation: sourceLocation)
        return r.result ?? WireResult(text: "")
    }

    func fails(_ who: (CallerInfo, Platform), _ op: WireOp, _ args: WireArgs = WireArgs(), _ code: RelayErrorCode,
               sourceLocation: SourceLocation = #_sourceLocation) {
        let r = call(who, op, args)
        #expect(!r.ok && r.error?.code == code, "期望 \(code.rawValue)，实际 \(r.error?.code.rawValue ?? "成功")", sourceLocation: sourceLocation)
    }

    /// 登记 codex-a（1）、codex-b（2）、claude-1（11）
    func registerAll() {
        _ = ok(codex(1), .register, WireArgs(mailbox: "codex-a"))
        _ = ok(codex(2), .register, WireArgs(mailbox: "codex-b"))
        _ = ok(claude(11), .register, WireArgs(mailbox: "claude-1"))
    }

    func waitFor(_ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !cond() && Date() < deadline { usleep(10_000) }
    }
}

@Suite("中转服务")
struct ServiceTests {
    @Test("登记：返回联系人；Claude 拿到等信命令；同一会话重复登记返回原信箱")
    func register() throws {
        let h = try Harness()
        let a = h.ok(h.codex(1), .register, WireArgs(mailbox: "codex-a"))
        #expect(a.mailbox == "codex-a")
        #expect(a.group == "组甲")
        #expect(a.waitCommand == nil)
        let c = h.ok(h.claude(11), .register, WireArgs(mailbox: "claude-1"))
        #expect(c.contacts?.map(\.mailbox) == ["codex-a"])
        #expect(c.waitCommand?.contains("relay-wait\" --mailbox claude-1 --home") == true)
        let again = h.ok(h.codex(1), .register, WireArgs(mailbox: "改名"))
        #expect(again.mailbox == "codex-a")
        #expect(again.text.contains("信箱名不变"))
        #expect(h.ok(h.codex(1), .contacts).contacts?.map(\.mailbox) == ["claude-1"])
        #expect(try h.service.store.session(platform: .claude, sessionID: sampleID(11))?.hostSessionID == "local_示例11")
    }

    @Test("完整来回：Codex → Claude（放标记、读信）→ Codex（按原会话排队，往返次数加 1）")
    func roundTrip() throws {
        let h = try Harness()
        h.registerAll()
        h.waits.set("claude-1", true)
        let sent = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "请看一下接口", subject: "接口"))
        #expect(sent.delivery == .pending)
        #expect(sent.hop == 1)
        #expect(sent.text.contains("马上被叫醒"))
        #expect(ClaudeMailbox(paths: h.paths).unreadMarker(mailbox: "claude-1") == 1)

        let inbox = h.ok(h.claude(11), .inbox)
        #expect(inbox.messages?.count == 1)
        let text = try #require(inbox.messages?.first?.text)
        #expect(text.hasPrefix("【传话 \(sent.messageID!)｜来自 codex-a（Codex · 项目甲）｜不是用户本人"))
        #expect(text.contains("主题：接口"))
        #expect(text.hasSuffix("请看一下接口"))
        #expect(inbox.text.contains("重新在后台运行等信命令"))
        #expect(ClaudeMailbox(paths: h.paths).unreadMarker(mailbox: "claude-1") == nil)
        #expect(h.ok(h.claude(11), .inbox).messages?.isEmpty == true)

        let reply = h.ok(h.claude(11), .send, WireArgs(to: "codex-a", body: "看过了", replyTo: sent.messageID, needsReply: false))
        #expect(reply.delivery == .queued)
        #expect(reply.chainID == sent.chainID)
        #expect(reply.hop == 2)
        #expect(h.codex.last?.thread == sampleID(1))
        #expect(h.codex.last?.text.contains("来回链 \(sent.chainID!) 第 2/6 次｜需要回复：否") == true)
        #expect(h.codex.last?.text.hasSuffix("看过了") == true)
        #expect(try h.service.store.message(id: sent.messageID!)?.repliedAt != nil)
        #expect(try h.service.store.message(id: reply.messageID!)?.queueRef == sampleID(99))
    }

    @Test("PROJECT_NOT_REGISTERED：目录没登记；项目被停用后立即生效")
    func projectNotRegistered() throws {
        let h = try Harness()
        h.fails(h.codex(31), .register, WireArgs(mailbox: "x"), .projectNotRegistered)
        _ = h.ok(h.codex(2), .register, WireArgs(mailbox: "codex-b"))
        try h.writeRegistry(disableB: true)
        h.fails(h.codex(2), .status, WireArgs(), .projectNotRegistered)
    }

    @Test("SESSION_NOT_REGISTERED：没登记就发信、收信")
    func sessionNotRegistered() throws {
        let h = try Harness()
        h.fails(h.codex(1), .send, WireArgs(to: "x", body: "y"), .sessionNotRegistered)
        h.fails(h.claude(11), .inbox, WireArgs(), .sessionNotRegistered)
    }

    @Test("IDENTITY_MISMATCH：自报编号不一致、目录对不上")
    func identityMismatch() throws {
        let h = try Harness()
        var c = h.codex(1)
        c.0.selfReportedSessionID = sampleID(2)
        h.fails(c, .register, WireArgs(mailbox: "x"), .identityMismatch)
        h.fails(h.codex(1, cwd: h.dirB), .register, WireArgs(mailbox: "x"), .identityMismatch)
    }

    @Test("MAILBOX_TAKEN 与交接：同组新会话要用户确认；确认后旧会话被拒、未读信转给新会话")
    func handoff() throws {
        let h = try Harness()
        h.registerAll()
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "给旧会话的信"))
        h.fails(h.claude(12), .register, WireArgs(mailbox: "claude-1"), .mailboxTaken)
        #expect(h.notices.get().contains { $0.kind == "交接" && $0.text.contains("handoff claude-1") })
        h.fails(h.claude(12), .inbox, WireArgs(), .sessionNotRegistered)
        _ = try h.service.confirmHandoff(mailbox: "claude-1")
        h.fails(h.claude(11), .inbox, WireArgs(), .sessionNotRegistered)
        let got = h.ok(h.claude(12), .inbox)
        #expect(got.messages?.count == 1)
        #expect(throws: RelayError.self) { try h.service.confirmHandoff(mailbox: "claude-1") }
    }

    @Test("MAILBOX_TAKEN：别组或别的平台占用了这个名字，不提供交接")
    func mailboxTakenOtherGroup() throws {
        let h = try Harness()
        _ = h.ok(h.claude(21), .register, WireArgs(mailbox: "same"))
        h.fails(h.claude(11), .register, WireArgs(mailbox: "same"), .mailboxTaken)
        h.fails(h.codex(1), .register, WireArgs(mailbox: "same"), .mailboxTaken)
        #expect(!h.notices.get().contains { $0.kind == "交接" })
    }

    @Test("RECIPIENT_NOT_FOUND 和 NOT_SAME_GROUP")
    func recipients() throws {
        let h = try Harness()
        h.registerAll()
        _ = h.ok(h.claude(21), .register, WireArgs(mailbox: "claude-other"))
        h.fails(h.codex(1), .send, WireArgs(to: "没有这个", body: "x"), .recipientNotFound)
        h.fails(h.codex(1), .send, WireArgs(to: "claude-other", body: "x"), .notSameGroup)
        h.fails(h.codex(1), .send, WireArgs(to: "codex-a", body: "x"), .invalidArgument)
        #expect(h.ok(h.claude(21), .contacts).contacts?.isEmpty == true)
    }

    @Test("HOP_LIMIT：同一来回链第 7 次被拒绝并通知")
    func hopLimit() throws {
        let h = try Harness()
        h.registerAll()
        var last = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "第 1 次"))
        for i in 2...6 {
            let fromClaude = i % 2 == 0
            last = h.ok(fromClaude ? h.claude(11) : h.codex(1), .send,
                        WireArgs(to: fromClaude ? "codex-a" : "claude-1", body: "第 \(i) 次", replyTo: last.messageID))
            #expect(last.hop == i)
        }
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: "第 7 次", replyTo: last.messageID), .hopLimit)
        #expect(h.notices.get().contains { $0.kind == "超限" })
    }

    @Test("回信只能回寄给自己的信，并寄回原发信人")
    func replyRules() throws {
        let h = try Harness()
        h.registerAll()
        let m = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "x"))
        h.fails(h.codex(2), .send, WireArgs(to: "codex-a", body: "y", replyTo: m.messageID), .invalidArgument)
        h.fails(h.claude(11), .send, WireArgs(to: "codex-b", body: "y", replyTo: m.messageID), .invalidArgument)
        h.fails(h.claude(11), .send, WireArgs(to: "codex-a", body: "y", replyTo: "M-20000101-0001"), .invalidArgument)
    }

    @Test("RATE_LIMIT：每对每小时、全部每小时")
    func rateLimit() throws {
        var limits = Limits()
        limits.pairPerHour = 2
        limits.totalPerHour = 3
        let h = try Harness(limits: limits)
        h.registerAll()
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "1"))
        _ = h.ok(h.claude(11), .send, WireArgs(to: "codex-a", body: "2"))
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: "3"), .rateLimit)
        _ = h.ok(h.codex(2), .send, WireArgs(to: "claude-1", body: "4"))
        h.fails(h.codex(2), .send, WireArgs(to: "codex-a", body: "5"), .rateLimit)
        h.now.set(h.now.get().addingTimeInterval(3_601))
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "一小时后"))
    }

    @Test("PAUSED：暂停后一律拒绝，恢复后不补发")
    func paused() throws {
        let h = try Harness()
        h.registerAll()
        try h.service.setPaused(true)
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: "x"), .paused)
        try h.service.setPaused(false)
        #expect(h.ok(h.claude(11), .inbox).messages?.isEmpty == true)
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "x"))
    }

    @Test("BODY_TOO_LONG 和空正文")
    func bodyLength() throws {
        let h = try Harness()
        h.registerAll()
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: String(repeating: "字", count: 20_001)), .bodyTooLong)
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: "  \n"), .invalidArgument)
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: String(repeating: "字", count: 20_000)))
    }

    @Test("SECRET_SUSPECTED：拦截并通知，只报类型")
    func secret() throws {
        let h = try Harness()
        h.registerAll()
        let token = "gh" + "p_" + String(repeating: "a", count: 36)
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: "令牌 \(token)"), .secretSuspected)
        let n = try #require(h.notices.get().last)
        #expect(n.kind == "拦截")
        #expect(!n.text.contains(token))
        #expect(try h.service.store.events(limit: 5).allSatisfy { !$0.summary.contains(token) })
    }

    @Test("DELIVERY_FAILED：找不到 codex 程序")
    func deliveryFailed() throws {
        let h = try Harness()
        h.registerAll()
        h.codex.script([.unavailable("找不到 codex 程序")])
        h.fails(h.claude(11), .send, WireArgs(to: "codex-a", body: "x"), .deliveryFailed)
        #expect(try h.service.store.recentMessages(limit: 1).first?.status == .failed)
        #expect(h.notices.get().contains { $0.kind == "投递失败" })
    }

    @Test("Codex 排队失败自动重试：重试成功记为已排队；三次都失败记为失败并通知")
    func retries() throws {
        let h = try Harness()
        h.registerAll()
        h.codex.script([.failed("一"), .failed("二"), .queued(ref: nil)])
        let r = h.ok(h.claude(11), .send, WireArgs(to: "codex-a", body: "x"))
        #expect(r.delivery == .retrying)
        h.waitFor { (try? h.service.store.message(id: r.messageID!)?.status) == .queued }
        #expect(try h.service.store.message(id: r.messageID!)?.status == .queued)
        #expect(h.codex.count == 3)

        h.codex.script([.failed("一"), .failed("二"), .failed("三"), .failed("四")])
        let r2 = h.ok(h.claude(11), .send, WireArgs(to: "codex-a", body: "y"))
        h.waitFor { (try? h.service.store.message(id: r2.messageID!)?.status) == .failed }
        #expect(try h.service.store.message(id: r2.messageID!)?.status == .failed)
        #expect(h.notices.get().contains { $0.kind == "投递失败" && $0.text.contains(r2.messageID!) })
        #expect(h.ok(h.claude(11), .status).text.contains("投递失败"))
    }

    @Test("给 Codex 的长信只送通知，全文用 relay_inbox 读")
    func longLetter() throws {
        let h = try Harness()
        h.registerAll()
        let body = String(repeating: "长", count: 8_001)
        let r = h.ok(h.claude(11), .send, WireArgs(to: "codex-a", body: body))
        #expect(r.delivery == .pending)
        #expect(h.codex.last?.text.contains("这是一封长信（8001 字）") == true)
        #expect(h.codex.last?.text.contains(body) == false)
        let inbox = h.ok(h.codex(1), .inbox)
        #expect(inbox.messages?.first?.text.hasSuffix(body) == true)
        #expect(inbox.waitCommand == nil)
    }

    @Test("定时检查：久等不到回信、Claude 未读没在等、ChatGPT 重启")
    func periodic() throws {
        let h = try Harness()
        h.registerAll()
        _ = h.ok(h.claude(11), .send, WireArgs(to: "codex-a", body: "要回复"))
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "给 Claude", needsReply: false))
        h.service.runPeriodicChecks()
        #expect(h.notices.get().isEmpty)

        h.now.set(h.now.get().addingTimeInterval(601))
        h.appServer.set(200)
        h.service.runPeriodicChecks()
        let kinds = h.notices.get().map(\.kind)
        #expect(kinds.contains("可能卡住"))
        #expect(kinds.contains("未读"))
        #expect(kinds.contains("Codex 重启"))
        #expect(h.notices.get().first { $0.kind == "Codex 重启" }?.text.contains("codex-a") == true)

        let before = h.notices.get().count
        h.service.runPeriodicChecks()
        #expect(h.notices.get().count == before, "同样的事不重复提醒")
    }
}
