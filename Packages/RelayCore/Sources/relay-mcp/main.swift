// relay-mcp：由 Codex、Claude 为每个会话拉起的 MCP 服务（标准输入输出）。
// 启动时不连中转核心、不记录；会话调用工具时才收集调用方信息并转给中转核心（设计方案第 5.2 节）。
import RelayMCP

MCPServer.live().run()
