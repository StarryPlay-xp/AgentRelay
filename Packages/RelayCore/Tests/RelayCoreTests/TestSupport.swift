import Foundation
@testable import RelayCore

/// 测试用临时目录：路径尽量短（本机通话口路径有 104 字节上限），用完删除。
final class TempDir: @unchecked Sendable {
    let path: String

    init() throws {
        let base = "/tmp/ar-test"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let dir = base + "/" + String(UUID().uuidString.prefix(8)).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 解析 /tmp → /private/tmp，和规范化后的路径一致
        path = PathMatcher.normalize(dir)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// 固定示例编号 00000000-0000-4000-8000-0000000000NN（隐私约定允许的写法）
func sampleID(_ n: Int) -> String {
    "00000000-0000-4000-8000-0000000000" + String(format: "%02d", n)
}

/// 合成的 Codex、Claude 会话记录
struct RecordFixture {
    let root: TempDir
    let external: ExternalPaths

    init() throws {
        root = try TempDir()
        external = ExternalPaths(codexSessions: root.path + "/codex/sessions", claudeProjects: root.path + "/claude/projects")
    }

    /// 写一份 Codex 会话记录：第一行是 session_meta，带 id 和 cwd
    func addCodex(_ id: String, cwd: String, day: String = "2026/11/13") throws {
        let dir = external.codexSessions + "/" + day
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let first = #"{"timestamp":"2026-11-13T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","originator":"测试"}}"#
        let second = #"{"type":"response_item","payload":{"text":"会话内容，不应被读取"}}"#
        try (first + "\n" + second + "\n").write(toFile: dir + "/rollout-2026-11-13T00-00-00-\(id).jsonl", atomically: true, encoding: .utf8)
    }

    /// 写一份 Claude 会话记录：开头几行没有 cwd，后面一行带 sessionId 和 cwd
    func addClaude(_ id: String, cwd: String, dirName: String = "-tmp-示例") throws {
        let dir = external.claudeProjects + "/" + dirName
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"summary","summary":"不相关"}"#,
            #"{"type":"user","sessionId":"\#(id)","cwd":"\#(cwd)","message":{"content":"会话内容，不应被读取"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/\(id).jsonl", atomically: true, encoding: .utf8)
    }
}
