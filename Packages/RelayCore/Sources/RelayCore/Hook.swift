import Darwin
import Foundation

/// relay-hook：Codex 钩子程序（调研报告第 7.3 节）。
///
/// Codex 在 UserPromptSubmit、PreToolUse、PostToolUse、Stop、Interrupt 时运行它，把事件 JSON 写进标准输入，
/// 读它打印的 JSON 决定拦不拦、补不补一段说明。规则：
/// - 没登记的会话（没有 `run/hook-sessions/<会话编号>` 标记）立刻放行，不连中转核心；
/// - 登记的会话：只把事件名、会话编号、轮次编号、工具名、`stop_hook_active` 交给中转核心，
///   **不带**用户输入的文字、命令内容、工具参数和输出；中转核心有引导信时返回要打印的输出；
/// - 出任何问题（AgentRelay 没运行、超时、看不懂输入）都放行：打印 `{}`、退出码 0，不挡 Codex 的正常工作。
public enum RelayHookCommand {
    public static let usage = "用法：relay-hook [--home <目录>]（由 Codex 的钩子调用，事件从标准输入读）"
    /// 处理的事件；别的事件直接放行
    public static let events: Set<String> = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt"]
    /// 等中转核心回复的上限（秒），要比钩子配置里给 Codex 的时限短
    public static let timeoutSeconds = 5
    /// 放行
    public static let pass = "{}"

    /// 解析参数（不含程序名）：返回 `--home` 的值；没给为 `.some(nil)`，参数不合法为 nil
    public static func parse(_ arguments: [String]) -> String?? {
        var home: String?
        var it = arguments.makeIterator()
        while let a = it.next() {
            switch a {
            case "--home": guard let v = it.next() else { return nil }; home = v
            default: return nil
            }
        }
        return .some(home)
    }

    /// 从钩子输入里取出要交给中转核心的几项；不是要处理的事件、不是登记的会话时返回 nil（放行）
    public static func event(from input: Data, paths: RelayPaths) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let name = obj["hook_event_name"] as? String, events.contains(name),
              let sid = obj["session_id"] as? String, SessionRecordLocator.isValidSessionID(sid),
              FileManager.default.fileExists(atPath: paths.hookSessionMarker(sid)) else { return nil }
        return HookEvent(event: name, sessionID: sid.lowercased(), turnID: obj["turn_id"] as? String,
                         toolName: obj["tool_name"] as? String, stopHookActive: obj["stop_hook_active"] as? Bool)
    }

    /// 处理一次，返回要打印的内容
    public static func run(input: Data, paths: RelayPaths, send: (HookEvent) -> WireResponse) -> String {
        guard let ev = event(from: input, paths: paths) else { return pass }
        let r = send(ev)
        guard r.ok, let out = r.result?.hookOutput, !out.isEmpty else { return pass }
        return out
    }

    public static func main() -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard let home = parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            print(pass)
            exit(0)
        }
        var env = ProcessInfo.processInfo.environment
        if let home { env["AGENTRELAY_HOME"] = home }
        let paths = RelayPaths.resolve(environment: env)
        // 读完标准输入（工具输出可能很大，只留前面一段用来取事件名和编号）
        var input = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            if input.count < Wire.maxLineBytes { input.append(chunk) }
        }
        let cwd = FileManager.default.currentDirectoryPath
        let out = run(input: input, paths: paths) { ev in
            SocketClient.send(op: .hook, caller: CallerInfo(cwd: cwd, codexThreadID: ev.sessionID), args: WireArgs(hook: ev),
                              paths: paths, timeout: timeoutSeconds)
        }
        print(out)
        exit(0)
    }
}
