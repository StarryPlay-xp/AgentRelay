import Foundation
import Testing
@testable import RelayCore

@Suite("登记表与路径匹配")
struct RegistryTests {
    @Test("规范化：去末尾斜杠、去 . 和 ..、/tmp 解析为 /private/tmp")
    func normalize() {
        #expect(PathMatcher.normalize("/tmp/") == "/private/tmp")
        #expect(PathMatcher.normalize("/private/tmp/a/../b/./c/") == "/private/tmp/b/c")
        #expect(PathMatcher.normalize("/") == "/")
    }

    @Test("规范化：不存在的路径解析存在的上级，再接上剩余部分")
    func normalizeMissing() {
        #expect(PathMatcher.normalize("/tmp/ar-不存在-1/子目录") == "/private/tmp/ar-不存在-1/子目录")
    }

    @Test("规范化：中文路径统一 Unicode 写法（分解形式和组合形式算同一个）")
    func normalizeUnicode() {
        let decomposed = "/private/tmp/e\u{301}"   // e + 组合重音
        let composed = "/private/tmp/\u{e9}"       // é
        #expect(PathMatcher.normalize(decomposed) == PathMatcher.normalize(composed))
    }

    @Test("规范化：解析符号链接")
    func normalizeSymlink() throws {
        let t = try TempDir()
        try FileManager.default.createDirectory(atPath: t.path + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: t.path + "/link", withDestinationPath: t.path + "/real")
        #expect(PathMatcher.normalize(t.path + "/link/x") == t.path + "/real/x")
    }

    @Test("等于或位于才算，前缀相同的兄弟目录不算")
    func within() {
        #expect(PathMatcher.isWithin("/a/b", root: "/a/b"))
        #expect(PathMatcher.isWithin("/a/b/c", root: "/a/b"))
        #expect(!PathMatcher.isWithin("/a/bc", root: "/a/b"))
        #expect(PathMatcher.isWithin("/a", root: "/"))
    }

    func sample() -> RegistryFile {
        RegistryFile(groups: ["组甲", "组乙"], projects: [
            .init(name: "项目甲", platform: .codex, group: "组甲", paths: ["/private/tmp/ar-reg/甲"]),
            .init(name: "项目甲-子目录", platform: .codex, group: "组乙", paths: ["/private/tmp/ar-reg/甲/子"]),
            .init(name: "项目甲-Claude", platform: .claude, group: "组甲", paths: ["/private/tmp/ar-reg/甲"],
                  extraPaths: ["/private/tmp/ar-reg/副本"]),
            .init(name: "未分组", platform: .claude, group: nil, paths: ["/private/tmp/ar-reg/乙"]),
            .init(name: "已停用", platform: .codex, group: "组甲", paths: ["/private/tmp/ar-reg/丙"], enabled: false),
        ])
    }

    @Test("按平台匹配，取最长；附加目录也算")
    func matching() throws {
        let r = try Registry(file: sample(), userHome: "/Users/<用户名>")
        #expect(r.project(for: .codex, containing: "/private/tmp/ar-reg/甲/x")?.name == "项目甲")
        #expect(r.project(for: .codex, containing: "/private/tmp/ar-reg/甲/子/y")?.name == "项目甲-子目录")
        #expect(r.project(for: .claude, containing: "/private/tmp/ar-reg/甲/子/y")?.name == "项目甲-Claude")
        #expect(r.project(for: .claude, containing: "/private/tmp/ar-reg/副本/z")?.name == "项目甲-Claude")
        #expect(r.project(for: .codex, containing: "/private/tmp/ar-reg/副本") == nil)
        #expect(r.project(for: .claude, containing: "/private/tmp/ar-reg/乙")?.isUsable == false)
        #expect(r.project(for: .codex, containing: "/private/tmp/ar-reg/丙")?.isUsable == false)
    }

    @Test("~ 展开为家目录")
    func tilde() throws {
        let f = RegistryFile(groups: ["g"], projects: [.init(name: "p", platform: .codex, group: "g", paths: ["~/示例项目"])])
        let r = try Registry(file: f, userHome: "/private/tmp/ar-home")
        #expect(r.projects[0].paths == ["/private/tmp/ar-home/示例项目"])
    }

    @Test("校验：重名、未知分组、空目录、相对路径都报错")
    func validation() {
        let g = ["g"]
        let bad: [RegistryFile] = [
            RegistryFile(groups: ["g", "g"], projects: []),
            RegistryFile(groups: g, projects: [.init(name: "p", platform: .codex, group: "g", paths: ["/a"]),
                                               .init(name: "p", platform: .claude, group: "g", paths: ["/b"])]),
            RegistryFile(groups: g, projects: [.init(name: "p", platform: .codex, group: "没有这个组", paths: ["/a"])]),
            RegistryFile(groups: g, projects: [.init(name: "p", platform: .codex, group: "g", paths: [])]),
            RegistryFile(groups: g, projects: [.init(name: "p", platform: .codex, group: "g", paths: ["相对/路径"])]),
        ]
        for file in bad {
            #expect(throws: RelayError.self) { try Registry(file: file, userHome: "/Users/<用户名>") }
        }
    }

    @Test("文件改了自动重读；读坏了保留上一次内容并报告一次错误")
    func reload() throws {
        let t = try TempDir()
        let path = t.path + "/registry.json"
        let store = RegistryStore(path: path, userHome: t.path)
        #expect(store.snapshot().registry == .empty)

        let enc = JSONEncoder()
        try enc.encode(RegistryFile(groups: ["g"], projects: [.init(name: "p", platform: .codex, group: "g", paths: ["/a"])]))
            .write(to: URL(fileURLWithPath: path))
        let first = store.snapshot()
        #expect(first.error == nil)
        #expect(first.registry.projects.count == 1)

        try Data("{坏的".utf8).write(to: URL(fileURLWithPath: path))
        let broken = store.snapshot()
        #expect(broken.error != nil)
        #expect(broken.registry.projects.count == 1)
        #expect(store.snapshot().error == nil)
    }
}
