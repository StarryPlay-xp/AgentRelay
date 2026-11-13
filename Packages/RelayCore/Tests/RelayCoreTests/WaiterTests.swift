import Foundation
import Testing
@testable import RelayCore

@Suite("等信")
struct WaiterTests {
    @Test("标记出现就结束，报出未读数")
    func wakes() async throws {
        let t = try TempDir()
        let paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": t.path + "/h"])
        try paths.prepare()
        let waiter = Waiter(paths: paths, mailbox: "claude-1", interval: 0.01)
        let task = Task.detached { waiter.wait() }
        try await Task.sleep(nanoseconds: 50_000_000)
        try ClaudeMailbox(paths: paths).setUnread(3, mailbox: "claude-1")
        #expect(await task.value == .newMail(3))
        #expect(Waiter.message(for: 3).contains("relay_inbox"))
    }

    @Test("信箱名不合规或运行目录不存在：直接报错，不等")
    func invalid() throws {
        let t = try TempDir()
        let paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": t.path + "/h"])
        if case .invalid = Waiter(paths: paths, mailbox: "claude-1").wait() {} else { Issue.record("运行目录不存在应当报错") }
        try paths.prepare()
        if case .invalid = Waiter(paths: paths, mailbox: "../x").wait() {} else { Issue.record("信箱名不合规应当报错") }
    }
}
