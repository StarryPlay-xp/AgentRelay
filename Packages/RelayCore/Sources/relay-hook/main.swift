// relay-hook：Codex 的钩子程序，把“立即引导”的信注入对方正在进行的一轮。逻辑在 RelayCore 的 RelayHookCommand 里，
// 应用内嵌的 relay-hook（Tools/relay-hook）调用同一个入口。
import RelayCore

RelayHookCommand.main()
