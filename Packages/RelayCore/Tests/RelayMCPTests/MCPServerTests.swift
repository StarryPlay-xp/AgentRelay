import Foundation
import Testing
import RelayCore
@testable import RelayMCP

final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(WireOp, CallerInfo, WireArgs)] = []
    var response: WireResponse = .success(WireResult(text: "好的"))
    func add(_ x: (WireOp, CallerInfo, WireArgs)) { lock.lock(); items.append(x); lock.unlock() }
    var last: (WireOp, CallerInfo, WireArgs)? { lock.lock(); defer { lock.unlock() }; return items.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

@Suite("relay-mcp 协议")
struct MCPServerTests {
    func server(env: [String: String] = [:]) -> (MCPServer, Captured) {
        let cap = Captured()
        let s = MCPServer(environment: env, cwd: "/private/tmp/示例项目") { op, caller, args in
            cap.add((op, caller, args))
            return cap.response
        }
        return (s, cap)
    }

    func json(_ line: String?) throws -> [String: Any] {
        let l = try #require(line)
        return try #require(try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])
    }

    func initialize(_ s: MCPServer, version: String, client: String) throws -> [String: Any] {
        let r = try json(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"\#(client)","version":"9.9"}}}"#))
        return try #require(r["result"] as? [String: Any])
    }

    @Test("握手：两边报的协议版本都照回；不认识的版本回最新；带使用说明", arguments: [
        ("2025-06-18", "2025-06-18"), ("2025-11-25", "2025-11-25"), ("2099-01-01", "2025-11-25"),
    ])
    func handshake(_ asked: String, _ expected: String) throws {
        let (s, cap) = server()
        let r = try initialize(s, version: asked, client: "codex-mcp-client")
        #expect(r["protocolVersion"] as? String == expected)
        #expect((r["serverInfo"] as? [String: Any])?["name"] as? String == "agentrelay")
        #expect((r["instructions"] as? String)?.contains("不是用户本人的话") == true)
        #expect((r["instructions"] as? String)?.contains("发完信就结束本轮回复") == true)
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(cap.count == 0, "握手时不连中转核心")
    }

    @Test("工具列表：五个工具，参数和必填项正确")
    func toolsList() throws {
        let (s, _) = server()
        let r = try json(s.handle(line: #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        let tools = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["relay_register", "relay_contacts", "relay_send", "relay_inbox", "relay_status"])
        let send = try #require(tools.first { $0["name"] as? String == "relay_send" }?["inputSchema"] as? [String: Any])
        #expect(send["required"] as? [String] == ["to", "body"])
        #expect(r["id"] as? String == "a")
    }

    @Test("Codex 调用：编号取自这次请求的 _meta.threadId；客户端名称随请求转发")
    func codexCall() throws {
        let (s, cap) = server()
        _ = try initialize(s, version: "2025-06-18", client: "codex-mcp-client")
        let id = "00000000-0000-4000-8000-000000000001"
        let r = try json(s.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"relay_send","arguments":{"to":"claude-1","body":"你好","needs_reply":false,"reply_to":"M-20261113-0001"},"_meta":{"threadId":"\#(id)","progressToken":1}}}"#))
        let (op, caller, args) = try #require(cap.last)
        #expect(op == .send)
        #expect(caller.codexThreadID == id)
        #expect(caller.cwd == "/private/tmp/示例项目")
        #expect(caller.clientName == "codex-mcp-client")
        #expect(caller.clientVersion == "9.9")
        #expect(caller.claudeSessionID == nil)
        #expect(args == WireArgs(to: "claude-1", body: "你好", replyTo: "M-20261113-0001", needsReply: false))
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String) == "好的")
    }

    @Test("Claude 调用：编号取自进程环境变量；register 的 session_id 作为自报")
    func claudeCall() throws {
        let id = "00000000-0000-4000-8000-000000000011"
        let (s, cap) = server(env: ["CLAUDE_CODE_SESSION_ID": id, "CLAUDE_CODE_HOST_SESSION_ID": "local_示例"])
        _ = try initialize(s, version: "2025-11-25", client: "claude-code")
        _ = s.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"relay_register","arguments":{"mailbox":"claude-1","session_id":"\#(id)"}}}"#)
        let (op, caller, args) = try #require(cap.last)
        #expect(op == .register)
        #expect(caller.claudeSessionID == id)
        #expect(caller.claudeHostSessionID == "local_示例")
        #expect(caller.selfReportedSessionID == id)
        #expect(caller.codexThreadID == nil)
        #expect(args.mailbox == "claude-1")
    }

    @Test("中转核心报错：返回 isError 和错误码")
    func errorResult() throws {
        let (s, cap) = server()
        cap.response = .failure(RelayError(.notSameGroup, "不在你的分组里"))
        let r = try json(s.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"relay_status","arguments":{}}}"#))
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String) == "错误 NOT_SAME_GROUP：不在你的分组里")
    }

    @Test("参数类型不对：不转发，直接报错")
    func badArgs() throws {
        let (s, cap) = server()
        let r = try json(s.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"relay_send","arguments":{"to":["a"],"body":"x"}}}"#))
        #expect((r["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(cap.count == 0)
    }

    @Test("未知工具、未知方法、ping、解析失败、客户端回复和通知")
    func protocolEdges() throws {
        let (s, _) = server()
        #expect(try json(s.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf"}}"#))["error"] != nil)
        let unknown = try json(s.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(try json(s.handle(line: #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#))["result"] != nil)
        #expect((try json(s.handle(line: "{坏")))["error"] != nil)
        #expect(s.handle(line: #"{"jsonrpc":"2.0","id":"x","result":{}}"#) == nil)
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#) == nil)
        #expect(s.handle(line: "   ") == nil)
    }
}
