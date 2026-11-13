import Foundation
import RelayCore

/// 应用运行日志（设计方案第 6 节：~/Library/Logs/AgentRelay/）。只记启动、窗口、退出这类事件，不写信件正文。
enum AppLog {
    static func write(_ text: String, paths: RelayPaths) {
        let file = paths.logs + "/app.log"
        if !FileManager.default.fileExists(atPath: file) {
            FileManager.default.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: file) else { return }
        h.seekToEndOfFile()
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        h.write(Data("[\(f.string(from: Date()))] \(text)\n".utf8))
        try? h.close()
    }
}
