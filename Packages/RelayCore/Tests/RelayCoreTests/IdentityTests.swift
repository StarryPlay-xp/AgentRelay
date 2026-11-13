import Foundation
import Testing
@testable import RelayCore

@Suite("会话记录与身份核对")
struct IdentityTests {
    let fx: RecordFixture
    let projectDir: String
    let registry: Registry
    let resolver: IdentityResolver

    init() throws {
        fx = try RecordFixture()
        projectDir = fx.root.path + "/项目甲"
        try FileManager.default.createDirectory(atPath: projectDir + "/子目录", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fx.root.path + "/未分组", withIntermediateDirectories: true)
        registry = try Registry(file: RegistryFile(groups: ["组甲"], projects: [
            .init(name: "项目甲", platform: .codex, group: "组甲", paths: [projectDir]),
            .init(name: "项目甲-Claude", platform: .claude, group: "组甲", paths: [projectDir]),
            .init(name: "未分组", platform: .codex, group: nil, paths: [fx.root.path + "/未分组"]),
        ]), userHome: fx.root.path)
        resolver = IdentityResolver(locator: SessionRecordLocator(paths: fx.external))
        try fx.addCodex(sampleID(1), cwd: projectDir)
        try fx.addCodex(sampleID(2), cwd: fx.root.path + "/未分组", day: "2026/11/12")
        try fx.addCodex(sampleID(3), cwd: "/private/tmp/没登记的目录")
        try fx.addClaude(sampleID(11), cwd: projectDir + "/子目录")
    }

    @Test("编号格式校验")
    func idFormat() {
        #expect(SessionRecordLocator.isValidSessionID(sampleID(1)))
        #expect(!SessionRecordLocator.isValidSessionID("../../etc"))
        #expect(!SessionRecordLocator.isValidSessionID("00000000-0000-4000-8000-00000000000g"))
        #expect(!SessionRecordLocator.isValidSessionID(""))
    }

    @Test("按编号找到 Codex、Claude 记录，只取目录")
    func locate() {
        let loc = SessionRecordLocator(paths: fx.external)
        #expect(loc.find(platform: .codex, sessionID: sampleID(1))?.cwd == projectDir)
        #expect(loc.find(platform: .codex, sessionID: sampleID(2)) != nil)
        #expect(loc.find(platform: .claude, sessionID: sampleID(11))?.cwd == projectDir + "/子目录")
        #expect(loc.find(platform: .claude, sessionID: sampleID(1)) == nil)
        #expect(loc.find(platform: .codex, sessionID: sampleID(99)) == nil)
    }

    @Test("Codex：按 _meta.threadId 认人，平台由签名决定")
    func codexMeta() throws {
        let id = try resolver.resolve(CallerInfo(cwd: projectDir, codexThreadID: sampleID(1)), peerPlatform: .codex, registry: registry)
        #expect(id.platform == .codex)
        #expect(id.sessionID == sampleID(1))
        #expect(id.source == .meta)
        #expect(id.project.name == "项目甲")
    }

    @Test("Claude：按环境变量认人，记下桌面版编号")
    func claudeEnv() throws {
        let id = try resolver.resolve(CallerInfo(cwd: projectDir + "/子目录", claudeSessionID: sampleID(11), claudeHostSessionID: "local_示例"),
                                      peerPlatform: .claude, registry: registry)
        #expect(id.source == .env)
        #expect(id.hostSessionID == "local_示例")
        #expect(id.project.name == "项目甲-Claude")
    }

    @Test("自报和可靠来源不一致：IDENTITY_MISMATCH")
    func selfReportMismatch() {
        #expect(throws: RelayError(.identityMismatch, "会话自报的编号和 Codex 给出的编号不一致")) {
            try resolver.resolve(CallerInfo(cwd: projectDir, codexThreadID: sampleID(1), selfReportedSessionID: sampleID(2)),
                                 peerPlatform: .codex, registry: registry)
        }
    }

    @Test("取不到可靠来源时退回自报，并标明来源")
    func selfReportFallback() throws {
        let id = try resolver.resolve(CallerInfo(cwd: projectDir, selfReportedSessionID: sampleID(1)), peerPlatform: .codex, registry: registry)
        #expect(id.source == .selfReported)
    }

    @Test("拒绝的几种情况", arguments: [
        ("没有编号", RelayErrorCode.identityMismatch, 0),
        ("找不到记录", .identityMismatch, 99),
        ("项目没分组", .projectNotRegistered, 2),
        ("目录没登记", .projectNotRegistered, 3),
    ])
    func rejections(_ name: String, _ code: RelayErrorCode, _ n: Int) {
        let caller = CallerInfo(cwd: "", codexThreadID: n == 0 ? nil : sampleID(n))
        do {
            _ = try resolver.resolve(caller, peerPlatform: .codex, registry: registry)
            Issue.record("\(name) 应当被拒绝")
        } catch let e as RelayError {
            #expect(e.code == code, "\(name)")
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test("relay-mcp 的工作目录和记录不一致：IDENTITY_MISMATCH")
    func cwdMismatch() {
        #expect(throws: RelayError.self) {
            try resolver.resolve(CallerInfo(cwd: projectDir + "/子目录", codexThreadID: sampleID(1)), peerPlatform: .codex, registry: registry)
        }
    }

    @Test("签名认出的是 Claude，就不认 Codex 的编号")
    func platformFromSignature() {
        #expect(throws: RelayError.self) {
            try resolver.resolve(CallerInfo(cwd: projectDir, codexThreadID: sampleID(1)), peerPlatform: .claude, registry: registry)
        }
    }

    @Test("放宽检查时从调用方信息推断平台")
    func infer() throws {
        #expect(try resolver.inferPlatform(CallerInfo(cwd: "", codexThreadID: sampleID(1))) == .codex)
        #expect(try resolver.inferPlatform(CallerInfo(cwd: "", claudeSessionID: sampleID(1))) == .claude)
        #expect(try resolver.inferPlatform(CallerInfo(cwd: "", clientName: "codex-mcp-client")) == .codex)
        #expect(throws: RelayError.self) { try resolver.inferPlatform(CallerInfo(cwd: "")) }
    }
}
