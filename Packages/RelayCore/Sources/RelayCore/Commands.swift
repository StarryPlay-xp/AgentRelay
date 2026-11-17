import Foundation

/// 运行一个外部命令的结果
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// 给人看的一句话：优先取报错输出的第一行
    public var brief: String {
        if timedOut { return "超时" }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return String(line.prefix(200))
    }
}

/// 运行外部命令（codex、claude、relay-mcp）。测试用假的实现，不碰真实程序。
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String],
             currentDirectory: String?, input: Data?, timeout: TimeInterval) -> CommandResult
}

/// 真的运行程序：分别收集标准输出和报错输出，超时就结束它
public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    currentDirectory: String?, input: Data?, timeout: TimeInterval) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        if let currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return CommandResult(status: 127, stderr: "启动失败：\(error.localizedDescription)")
        }
        let outCollector = OutputCollector(out.fileHandleForReading)
        let errCollector = OutputCollector(err.fileHandleForReading)
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return CommandResult(status: -1, stdout: outCollector.finish(), stderr: errCollector.finish(), timedOut: true)
        }
        return CommandResult(status: p.terminationStatus, stdout: outCollector.finish(), stderr: errCollector.finish())
    }

    /// 从应用里运行命令时的环境：沿用当前环境，再给 PATH 补上常见位置和程序所在目录。
    /// 从访达打开的应用只有很短的 PATH，用 npm 装的 codex、claude 会找不到 node。
    public static func environment(for executable: String, base: [String: String] = ProcessInfo.processInfo.environment,
                                   userHome: String = RelayPaths.userHome(), extra: [String: String] = [:]) -> [String: String] {
        var env = base
        let exeDir = (executable as NSString).deletingLastPathComponent
        let wanted = [exeDir, userHome + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for dir in wanted where !parts.contains(dir) { parts.append(dir) }
        env["PATH"] = parts.joined(separator: ":")
        for (k, v) in extra { env[k] = v }
        return env
    }
}

/// 在后台读完子进程输出，避免输出太多时子进程卡住。
/// 用独立线程读：读可能阻塞很久，放在 GCD 全局队列上，调用方又在同步等它时，线程池被占满就会互相卡住
final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            let d = handle.readDataToEndOfFile()
            lock.lock()
            data = d
            lock.unlock()
            finished.signal()
        }
    }

    func finish() -> String {
        _ = finished.wait(timeout: .now() + 2)
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Claude Code 的命令行程序 `claude`
public enum ClaudeCLI {
    /// 查找顺序：设置里填的 → 官方安装位置 `~/.local/bin/claude` → Homebrew、/usr/local → 旧的本地安装位置 →
    /// PATH 里的 → 最后才用桌面版自带的那份（路径随版本变，只作兜底）。测试必须传入假的路径，不能用默认的查找。
    public static func locate(configuredPath: String?, userHome: String = RelayPaths.userHome(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if let configuredPath, !configuredPath.isEmpty, fm.isExecutableFile(atPath: configuredPath) { return configuredPath }
        var candidates = [userHome + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", userHome + "/.claude/local/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        return bundledWithDesktop(userHome: userHome)
    }

    /// 桌面版自带的 Claude Code：`~/Library/Application Support/Claude*/claude-code/<版本>/…/claude`，取修改时间最新的一份
    static func bundledWithDesktop(userHome: String) -> String? {
        let fm = FileManager.default
        let support = userHome + "/Library/Application Support"
        let apps = ((try? fm.contentsOfDirectory(atPath: support)) ?? []).filter { $0.hasPrefix("Claude") }
        var found: [(String, Date)] = []
        for app in apps {
            let root = support + "/" + app + "/claude-code"
            guard let walker = fm.enumerator(atPath: root) else { continue }
            while let rel = walker.nextObject() as? String {
                // 只看几层深，避免走遍整个目录
                if rel.split(separator: "/").count > 6 { walker.skipDescendants(); continue }
                guard (rel as NSString).lastPathComponent == "claude" else { continue }
                let full = root + "/" + rel
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: full) else { continue }
                let date = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? .distantPast
                found.append((full, date))
            }
        }
        return found.max { $0.1 < $1.1 }?.0
    }
}
