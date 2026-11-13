// relay-wait：Claude 会话在后台运行的等信程序。
// 用法：relay-wait --mailbox <信箱名> [--home <AGENTRELAY_HOME>]
// 有新信时打印一句提示并以 0 退出；参数不对以 2 退出。
import Foundation
import RelayCore

var mailbox: String?
var home: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--mailbox": mailbox = args.next()
    case "--home": home = args.next()
    default:
        FileHandle.standardError.write(Data("用法：relay-wait --mailbox <信箱名> [--home <目录>]\n".utf8))
        exit(2)
    }
}
guard let mailbox else {
    FileHandle.standardError.write(Data("用法：relay-wait --mailbox <信箱名> [--home <目录>]\n".utf8))
    exit(2)
}
var env = ProcessInfo.processInfo.environment
if let home { env["AGENTRELAY_HOME"] = home }
switch Waiter(paths: RelayPaths.resolve(environment: env), mailbox: mailbox).wait() {
case .newMail(let n):
    print(Waiter.message(for: n))
    exit(0)
case .invalid(let why):
    print("等信没法开始：\(why)")
    exit(2)
}
