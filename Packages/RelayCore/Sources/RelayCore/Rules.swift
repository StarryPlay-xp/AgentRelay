import Foundation

/// 护栏的各项上限（设计方案第 14 节；默认值见第 24 节第 2 项）。
public struct Limits: Sendable, Equatable {
    /// 同一来回链最多往返几次
    public var hopLimit = 6
    /// 每两个信箱之间每小时最多几条（两个方向合计）
    public var pairPerHour = 20
    /// 全部合计每小时最多几条
    public var totalPerHour = 100
    /// 单封正文最多几个字
    public var maxBodyCharacters = 20_000
    /// 给 Codex 的信超过几个字改为“长信通知”
    public var codexInlineMaxCharacters = 8_000
    /// 信件和记录保留几天
    public var retentionDays = 30
    /// Claude 没在等信时，过多久通知你（秒）
    public var claudeUnreadNotifyAfter: TimeInterval = 120
    /// 需要回复的信，过多久没回标“可能卡住”（秒）
    public var replyStaleAfter: TimeInterval = 600
    /// ChatGPT 重启时，往前看多久内收过信的 Codex 信箱（秒）
    public var restartLookback: TimeInterval = 1_800

    public init() {}
}

/// 信箱名规则：小写字母、数字和 `-`，以字母或数字开头，最长 32 个字符，例如 `codex-a`、`claude-1`。
public enum MailboxName {
    public static let maxLength = 32

    public static func validate(_ name: String) throws {
        guard !name.isEmpty, name.count <= maxLength else {
            throw RelayError(.invalidArgument, "信箱名要 1～\(maxLength) 个字符")
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard name.allSatisfy({ allowed.contains($0) }), name.first != "-" else {
            throw RelayError(.invalidArgument, "信箱名只能用小写字母、数字和 -，并以字母或数字开头，例如 codex-a、claude-1")
        }
    }
}

/// 疑似密钥检测：命中就拒绝发送，只报类型，不记录内容（设计方案第 14 节）。
/// 令牌规则和 `scripts/privacy-check.sh` 保持一致。
public enum SecretScanner {
    private static let rules: [(type: String, regex: NSRegularExpression)] = {
        let patterns: [(String, String)] = [
            ("私钥", "-----BEGIN [A-Z ]*PRIVATE KEY-----"),
            ("GitHub 令牌", "(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gh[ousr]_[A-Za-z0-9]{36})"),
            ("API 密钥", "sk-[A-Za-z0-9_-]{20,}"),
            ("Slack 令牌", "xox[abprs]-[A-Za-z0-9-]{10,}"),
            ("AWS 访问密钥", "AKIA[0-9A-Z]{16}"),
            ("Google API 密钥", "AIza[0-9A-Za-z_-]{35}"),
            ("JWT", "eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"),
        ]
        return patterns.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }
    }()

    /// 返回命中的类型（去重，按规则顺序）；没有命中返回空数组。
    public static func scan(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return rules.compactMap { rule in
            rule.regex.firstMatch(in: text, range: range) == nil ? nil : rule.type
        }
    }
}
