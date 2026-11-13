import Foundation
import Testing
@testable import RelayCore

/// 信箱主人标记与等信认主（2026-11-13 实机验收发现：交接后旧会话的等信命令还在等，会被给新会话的信叫醒）
@Suite("等信认主")
struct MailboxOwnerTests {
    private func token(_ n: Int) -> String { MailboxOwner.token(sessionID: sampleID(n)) }

    @Test("短码：由会话编号算出，12 位十六进制，不含编号原文；同一会话不变，不同会话不同")
    func tokens() {
        #expect(token(11) == token(11))
        #expect(token(11) != token(12))
        #expect(token(11).count == 12)
        #expect(token(11).allSatisfy { $0.isHexDigit })
        #expect(!sampleID(11).contains(token(11)))
    }

    @Test("登记后信箱记下主人；交接确认后旧会话的等信自己结束，新会话的照常等、有信就醒")
    func handoff() throws {
        let h = try Harness()
        h.registerAll()
        let box = ClaudeMailbox(paths: h.paths)
        #expect(box.owner(mailbox: "claude-1") == token(11))
        let oldWaiter = Waiter(paths: h.paths, mailbox: "claude-1", owner: token(11))
        #expect(oldWaiter.poll() == nil)

        h.fails(h.claude(12), .register, WireArgs(mailbox: "claude-1"), .mailboxTaken)
        #expect(oldWaiter.poll() == nil, "交接确认前旧会话照常等信")
        _ = try h.service.confirmHandoff(mailbox: "claude-1")
        #expect(box.owner(mailbox: "claude-1") == token(12))
        #expect(oldWaiter.poll() == .notOwner)
        #expect(Waiter.notOwnerMessage(mailbox: "claude-1").contains("relay_status"))

        let newWaiter = Waiter(paths: h.paths, mailbox: "claude-1", owner: token(12))
        let got = h.ok(h.claude(12), .register, WireArgs(mailbox: "claude-1"))
        #expect(got.waitCommand?.contains("--owner \(token(12))") == true)
        #expect(newWaiter.poll() == nil)
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "给新会话的信"))
        #expect(newWaiter.poll() == .newMail(1))
        #expect(oldWaiter.poll() == .notOwner, "给新会话的信不能叫醒旧会话")
    }

    @Test("改名、停用后等在旧名字上的等信自己结束；重新启用后主人恢复")
    func renameAndDisable() throws {
        let h = try Harness()
        h.registerAll()
        let box = ClaudeMailbox(paths: h.paths)
        let s = try #require(try h.service.store.session(platform: .claude, sessionID: sampleID(11)))

        try h.service.renameMailbox(session: s.id, to: "claude-new")
        #expect(box.owner(mailbox: "claude-1") == MailboxOwner.none)
        #expect(box.owner(mailbox: "claude-new") == token(11))
        #expect(Waiter(paths: h.paths, mailbox: "claude-1", owner: token(11)).poll() == .notOwner)
        let renamed = Waiter(paths: h.paths, mailbox: "claude-new", owner: token(11))
        #expect(renamed.poll() == nil)
        #expect(h.ok(h.claude(11), .status).waitCommand?.contains("--mailbox claude-new --owner \(token(11))") == true)

        try h.service.setSessionEnabled(id: s.id, false)
        #expect(box.owner(mailbox: "claude-new") == MailboxOwner.none)
        #expect(renamed.poll() == .notOwner)
        try h.service.setSessionEnabled(id: s.id, true)
        #expect(box.owner(mailbox: "claude-new") == token(11))
    }

    @Test("兼容：旧版等信命令（不带短码）照旧等；还没有主人标记时带短码的也照旧等")
    func compatibility() throws {
        let t = try TempDir()
        let paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": t.path + "/h"])
        try paths.prepare()
        let box = ClaudeMailbox(paths: paths)
        #expect(Waiter(paths: paths, mailbox: "claude-1", owner: "0a1b2c3d4e5f").poll() == nil)
        try box.setOwner(nil, mailbox: "claude-1")
        #expect(box.owner(mailbox: "claude-1") == nil, "没有主人、信箱目录也不存在时不建目录")
        try box.setOwner("0a1b2c3d4e5f", mailbox: "claude-1")
        try box.setOwner(nil, mailbox: "claude-1")
        #expect(box.owner(mailbox: "claude-1") == MailboxOwner.none)
        #expect(Waiter(paths: paths, mailbox: "claude-1").poll() == nil)
        try box.setUnread(2, mailbox: "claude-1")
        #expect(Waiter(paths: paths, mailbox: "claude-1").poll() == .newMail(2))
    }

    @Test("定时检查补齐主人标记（例如运行目录被清空后）")
    func periodicSync() throws {
        let h = try Harness()
        h.registerAll()
        unlink(h.paths.mailboxOwner("claude-1"))
        #expect(ClaudeMailbox(paths: h.paths).owner(mailbox: "claude-1") == nil)
        h.service.runPeriodicChecks()
        #expect(ClaudeMailbox(paths: h.paths).owner(mailbox: "claude-1") == token(11))
    }

    @Test("判断谁在等：只算当前主人的等信；不带短码的旧命令照旧算在等")
    func detector() {
        let parsed = ProcessWaitDetector.waiter(arguments: ["--mailbox", "claude-1", "--owner", "abc", "--home", "/h"])
        #expect(parsed?.mailbox == "claude-1")
        #expect(parsed?.owner == "abc")
        #expect(ProcessWaitDetector.waiter(arguments: ["--mailbox", "claude-1"])?.owner == nil)
        #expect(ProcessWaitDetector.waiter(arguments: ["--home", "/h"]) == nil)
        #expect(ProcessWaitDetector.matches(("claude-1", "abc"), mailbox: "claude-1", owner: "abc"))
        #expect(!ProcessWaitDetector.matches(("claude-1", "old"), mailbox: "claude-1", owner: "abc"))
        #expect(ProcessWaitDetector.matches(("claude-1", nil), mailbox: "claude-1", owner: "abc"))
        #expect(!ProcessWaitDetector.matches(("claude-2", "abc"), mailbox: "claude-1", owner: "abc"))
    }

    @Test("拒绝交接：全新会话的申请删掉登记；已被接手的旧会话再来申请，被拒后恢复原样（含原信箱名）")
    func rejectRestores() throws {
        let h = try Harness()
        h.registerAll()
        let store = h.service.store
        // 全新会话申请被拒：登记删掉
        h.fails(h.claude(12), .register, WireArgs(mailbox: "claude-1"), .mailboxTaken)
        try h.service.rejectHandoff(mailbox: "claude-1")
        #expect(try store.session(platform: .claude, sessionID: sampleID(12)) == nil)

        // 12 接手 claude-1，11 变成已被接手；12 再改名为 claude-x
        h.fails(h.claude(12), .register, WireArgs(mailbox: "claude-1"), .mailboxTaken)
        _ = try h.service.confirmHandoff(mailbox: "claude-1")
        let old = try #require(try store.session(platform: .claude, sessionID: sampleID(11)))
        #expect(old.status == .replaced)
        let new = try #require(try store.session(platform: .claude, sessionID: sampleID(12)))
        try h.service.renameMailbox(session: new.id, to: "claude-x")

        // 旧会话 11 想要回 claude-x：被拒绝后恢复成“已被接手”，信箱名回到 claude-1，登记不删
        h.fails(h.claude(11), .register, WireArgs(mailbox: "claude-x"), .mailboxTaken)
        #expect(try store.session(id: old.id)?.status == .pendingHandoff)
        try h.service.rejectHandoff(mailbox: "claude-x")
        let restored = try #require(try store.session(id: old.id))
        #expect(restored.status == .replaced)
        #expect(restored.mailbox == "claude-1")
        #expect(restored.registeredAt == old.registeredAt)
        #expect(try store.takeHandoffRestore(session: old.id) == nil, "用过的恢复记录要删掉")
        #expect(try store.session(id: new.id)?.status == .active)
        #expect(ClaudeMailbox(paths: h.paths).owner(mailbox: "claude-x") == token(12))

        // 再申请并被确认：恢复记录也要清掉
        h.fails(h.claude(11), .register, WireArgs(mailbox: "claude-x"), .mailboxTaken)
        _ = try h.service.confirmHandoff(mailbox: "claude-x")
        #expect(try store.takeHandoffRestore(session: old.id) == nil)
        #expect(try store.session(id: old.id)?.status == .active)
    }
}
