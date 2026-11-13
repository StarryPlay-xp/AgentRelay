import Foundation

/// 本机会话记录里查到的信息：只有目录（设计方案第 8.1 节第 2 点）
public struct SessionRecord: Sendable, Equatable {
    public let platform: Platform
    public let sessionID: String
    public let cwd: String
}

public protocol SessionRecordLocating: Sendable {
    func find(platform: Platform, sessionID: String) -> SessionRecord?
}

/// 按编号只读查找 Codex、Claude 的会话记录，只取 `cwd`，不读会话内容。
public final class SessionRecordLocator: SessionRecordLocating, @unchecked Sendable {
    private let paths: ExternalPaths
    private let lock = NSLock()
    private var cache: [String: SessionRecord] = [:]
    /// 第一行（或开头若干行）最多读多少字节；Codex 第一行可能带较长的元数据
    private let maxHeadBytes = 4 * 1024 * 1024
    private let maxClaudeLines = 200

    public init(paths: ExternalPaths) {
        self.paths = paths
    }

    /// 编号必须是 UUID 形式（8-4-4-4-12 位十六进制），防止拿编号拼出奇怪的路径。
    public static func isValidSessionID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    public func find(platform: Platform, sessionID: String) -> SessionRecord? {
        guard Self.isValidSessionID(sessionID) else { return nil }
        let key = platform.rawValue + ":" + sessionID.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let found: SessionRecord?
        switch platform {
        case .codex: found = findCodex(sessionID)
        case .claude: found = findClaude(sessionID)
        }
        if let found {
            lock.lock()
            cache[key] = found
            lock.unlock()
        }
        return found
    }

    // MARK: Codex：~/.codex/sessions/<年>/<月>/<日>/rollout-…-<编号>.jsonl，只读第一行的 payload.cwd

    private func findCodex(_ id: String) -> SessionRecord? {
        let suffix = "-" + id.lowercased() + ".jsonl"
        let fm = FileManager.default
        // 按年、月、日倒序找，新会话通常在最近的目录里
        for year in sortedSubdirs(paths.codexSessions) {
            for month in sortedSubdirs(year) {
                for day in sortedSubdirs(month) {
                    guard let names = try? fm.contentsOfDirectory(atPath: day) else { continue }
                    for name in names where name.hasPrefix("rollout-") && name.lowercased().hasSuffix(suffix) {
                        guard let line = readLines(day + "/" + name, maxLines: 1).first,
                              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let payload = obj["payload"] as? [String: Any],
                              let cwd = payload["cwd"] as? String else { continue }
                        if let pid = payload["id"] as? String, pid.lowercased() != id.lowercased() { continue }
                        return SessionRecord(platform: .codex, sessionID: id, cwd: cwd)
                    }
                }
            }
        }
        return nil
    }

    private func sortedSubdirs(_ dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map { dir + "/" + $0 }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    }

    // MARK: Claude：~/.claude/projects/<目录名编码>/<编号>.jsonl，只读开头若干行里的 cwd 和 sessionId

    private func findClaude(_ id: String) -> SessionRecord? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: paths.claudeProjects) else { return nil }
        for dir in dirs where !dir.hasPrefix(".") {
            let file = paths.claudeProjects + "/" + dir + "/" + id + ".jsonl"
            guard FileManager.default.fileExists(atPath: file) else { continue }
            for line in readLines(file, maxLines: maxClaudeLines) {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let sid = obj["sessionId"] as? String, sid.lowercased() == id.lowercased(),
                      let cwd = obj["cwd"] as? String else { continue }
                return SessionRecord(platform: .claude, sessionID: id, cwd: cwd)
            }
        }
        return nil
    }

    private func readLines(_ path: String, maxLines: Int) -> [Data] {
        Self.readLines(path, maxLines: maxLines, maxBytes: maxHeadBytes)
    }

    /// 读文件开头的若干行（不超过 maxBytes）
    static func readLines(_ path: String, maxLines: Int, maxBytes: Int = 4 * 1024 * 1024) -> [Data] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        var buffer = Data()
        var lines: [Data] = []
        while lines.count < maxLines && buffer.count <= maxBytes {
            guard let chunk = try? fh.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                if !buffer.isEmpty { lines.append(buffer) }
                break
            }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A), lines.count < maxLines {
                lines.append(buffer[buffer.startIndex..<nl])
                buffer = buffer[(nl + 1)...]
            }
            buffer = Data(buffer)
        }
        return lines
    }
}
