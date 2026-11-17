import Darwin
import Foundation

@_silgen_name("proc_pidpath")
private func c_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

@_silgen_name("proc_listallpids")
private func c_proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

/// 读取本机进程信息（只读）：可执行文件路径、父进程、所属用户、启动参数。
public enum Processes {
    public static func executablePath(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { c_proc_pidpath(pid, $0.baseAddress!, UInt32($0.count)) }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    public static func parent(of pid: pid_t) -> pid_t? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    public static func owner(of pid: pid_t) -> uid_t? {
        kinfo(pid).map { $0.kp_eproc.e_ucred.cr_uid }
    }

    /// 所有进程号
    public static func allPIDs() -> [pid_t] {
        let count = c_proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { c_proc_listallpids($0.baseAddress!, Int32($0.count)) }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    /// 启动参数（只对本用户的进程有效）。不读环境变量。
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        // 跳过可执行文件路径和后面的填充 0
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// 本用户的进程里，满足条件的那些
    public static func find(_ match: (pid_t, String, [String]) -> Bool) -> [pid_t] {
        let me = getuid()
        return allPIDs().filter { pid in
            guard owner(of: pid) == me, let path = executablePath(pid), let args = arguments(of: pid) else { return false }
            return match(pid, path, args)
        }
    }
}

/// ChatGPT 里正在运行的 Codex 后台服务（`codex app-server`）
public struct CodexAppServer: Sendable, Equatable {
    public let pid: pid_t
    public let executable: String

    /// 找正在运行的 Codex 后台服务；有多个时优先 ChatGPT 自带的那份
    public static func running() -> CodexAppServer? {
        var found: [CodexAppServer] = []
        for pid in Processes.find({ _, path, args in
            (path as NSString).lastPathComponent == "codex" && args.contains("app-server")
        }) {
            if let path = Processes.executablePath(pid) { found.append(CodexAppServer(pid: pid, executable: path)) }
        }
        return found.first { $0.executable.contains("/ChatGPT.app/") } ?? found.first
    }

    /// 这个进程号现在还是不是本用户的 codex 程序（钩子上报时记下的后台服务是否还在）
    public static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0, Processes.owner(of: pid) == getuid(), let path = Processes.executablePath(pid) else { return false }
        return (path as NSString).lastPathComponent == "codex"
    }
}
