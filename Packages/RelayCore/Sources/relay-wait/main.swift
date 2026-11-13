// relay-wait：Claude 会话在后台运行的等信程序。逻辑在 RelayCore 的 RelayWaitCommand 里，
// 应用内嵌的 relay-wait（Tools/relay-wait）调用同一个入口。
import RelayCore

RelayWaitCommand.main()
