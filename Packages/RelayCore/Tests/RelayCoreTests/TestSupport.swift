import Foundation

/// 测试用临时目录：路径尽量短（本机通话口路径有 104 字节上限），用完删除。
final class TempDir: @unchecked Sendable {
    let path: String

    init() throws {
        let base = "/tmp/ar-test"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let dir = base + "/" + String(UUID().uuidString.prefix(8)).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 解析 /tmp → /private/tmp，和规范化后的路径一致
        path = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}
