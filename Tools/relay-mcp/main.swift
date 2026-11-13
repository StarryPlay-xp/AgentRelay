// 应用内嵌的 relay-mcp（装进 AgentRelay.app/Contents/Helpers/）。逻辑在 RelayMCP 库里，和包里的 relay-mcp 相同。
import RelayMCP

MCPServer.live().run()
