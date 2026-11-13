import Foundation

/// 返回给会话的错误码（设计方案第 9.2 节），外加几个内部错误。
public enum RelayErrorCode: String, Codable, Sendable, CaseIterable {
    case relayNotRunning = "RELAY_NOT_RUNNING"
    case projectNotRegistered = "PROJECT_NOT_REGISTERED"
    case sessionNotRegistered = "SESSION_NOT_REGISTERED"
    case identityMismatch = "IDENTITY_MISMATCH"
    case mailboxTaken = "MAILBOX_TAKEN"
    case recipientNotFound = "RECIPIENT_NOT_FOUND"
    case notSameGroup = "NOT_SAME_GROUP"
    case hopLimit = "HOP_LIMIT"
    case rateLimit = "RATE_LIMIT"
    case paused = "PAUSED"
    case bodyTooLong = "BODY_TOO_LONG"
    case secretSuspected = "SECRET_SUSPECTED"
    case deliveryFailed = "DELIVERY_FAILED"
    /// 参数不对（信箱名不合规、缺少必填参数、回信对象不对等）
    case invalidArgument = "INVALID_ARGUMENT"
    /// 本机通话口版本不一致
    case versionMismatch = "VERSION_MISMATCH"
    /// 其他内部错误
    case internalError = "INTERNAL_ERROR"
}

public struct RelayError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: RelayErrorCode
    public let message: String

    public init(_ code: RelayErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue)：\(message)" }
}
