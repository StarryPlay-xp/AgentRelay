import Foundation

/// 结果未知时的核对（调研报告第 7.2 节第 1 点）：起一个 `codex app-server`（标准输入输出，和 `codex queue`
/// 用的内嵌服务是同一套），只做两次查询，不写任何东西：
/// - `thread/queue/list`：对方的排队里有没有这封信；
/// - `thread/turns/list`：最近几轮的用户消息里有没有（信已经被执行了）。
/// 按信封第一行开头的“【传话 <信件编号>｜”找。`thread/queue/*` 是 Codex 的实验性接口，会随版本变；查不了就返回 nil。
public struct CodexAppServerQueueChecker: CodexQueueChecking {
    public let executable: @Sendable () -> String?
    /// Codex 的数据目录（`CODEX_HOME`，默认 `~/.codex`）：用来看本机有没有共享后台服务
    public let codexHome: String
    public let timeout: TimeInterval
    /// 查最近几轮
    public let recentTurns: Int

    public init(codexHome: String, timeout: TimeInterval = 20, recentTurns: Int = 10, executable: @escaping @Sendable () -> String?) {
        self.codexHome = codexHome
        self.timeout = timeout
        self.recentTurns = recentTurns
        self.executable = executable
    }

    /// 默认的 Codex 数据目录：`CODEX_HOME` 有值时按它来
    public static func defaultCodexHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        userHome: String = RelayPaths.userHome()) -> String {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome + "/.codex"
        return RelayPaths.expandTilde(home, userHome: userHome)
    }

    public func contains(threadID: String, messageID: String) -> Bool? {
        guard let exe = executable(), FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        // 本机有共享后台服务时不另起服务（codex queue 也会避开这种情况），直接算“查不了”
        if FileManager.default.fileExists(atPath: codexHome + "/app-server-control/app-server-control.sock") { return nil }
        guard let rpc = JSONRPCProcess(executable: exe, arguments: ["app-server"], timeout: timeout) else { return nil }
        defer { rpc.close() }
        guard rpc.request("initialize", [
            "clientInfo": ["name": "agentrelay_queue_check", "title": "AgentRelay", "version": "1"],
            "capabilities": ["experimentalApi": true],
        ]) != nil else { return nil }
        rpc.notify("initialized")
        let needle = Envelope.headlinePrefix(messageID: messageID)
        guard let queued = rpc.request("thread/queue/list", ["threadId": threadID, "limit": 100]) else { return nil }
        if Self.containsString(queued, needle) { return true }
        guard let turns = rpc.request("thread/turns/list", ["threadId": threadID, "limit": recentTurns, "itemsView": "full"]) else {
            return nil
        }
        return Self.containsString(turns, needle)
    }

    /// JSON 里任何一个字符串包含 `needle`
    static func containsString(_ value: Any, _ needle: String) -> Bool {
        switch value {
        case let s as String: return s.contains(needle)
        case let a as [Any]: return a.contains { containsString($0, needle) }
        case let d as [String: Any]: return d.values.contains { containsString($0, needle) }
        default: return false
        }
    }
}

/// 一问一答的 JSON-RPC 子进程（一行一条，没有 "jsonrpc" 字段也接受）。只给核对用，用完就关。
final class JSONRPCProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: TimeInterval
    private let cond = NSCondition()
    private var lines: [Data] = []
    private var closed = false
    private var nextID = 1

    init?(executable: String, arguments: [String], timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let handle = output.fileHandleForReading
        Thread.detachNewThread { [self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                cond.lock()
                if chunk.isEmpty {
                    closed = true
                    cond.broadcast()
                    cond.unlock()
                    return
                }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    lines.append(Data(buffer[buffer.startIndex..<nl]))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                cond.broadcast()
                cond.unlock()
            }
        }
    }

    private func write(_ obj: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return false }
        data.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { return false }
        return true
    }

    func notify(_ method: String) {
        _ = write(["method": method])
    }

    /// 发一个请求，等到对应编号的回复；出错、超时返回 nil，成功返回 `result`
    func request(_ method: String, _ params: [String: Any]) -> Any? {
        let id = nextID
        nextID += 1
        guard write(["id": id, "method": method, "params": params]) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while true {
            while let line = lines.first {
                lines.removeFirst()
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (obj["id"] as? Int) == id, obj["method"] == nil else { continue }
                return obj["error"] == nil ? obj["result"] : nil
            }
            if closed { return nil }
            if !cond.wait(until: deadline) { return nil }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
