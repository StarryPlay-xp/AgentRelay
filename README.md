# AgentRelay

让本机上的 AI 编程会话互相传话的 macOS 应用：Codex（ChatGPT 桌面版内置）和 Claude 桌面版（Claude Code）里登记过的会话，可以通过 MCP 工具直接给对方发信、回信，不用人在中间复制粘贴。

> 状态：开发中，还不能使用。

AgentRelay 是独立的开源项目，不是 Anthropic 或 OpenAI 的官方产品，也没有得到它们的认可或合作。“Claude”“Claude Code”“Codex”“ChatGPT”是各自所有者的商标，本项目只用它们说明可以配合哪些软件使用。

## 它会做什么

- 只在本机运行，不联网，没有任何统计或上报。
- 只对你在应用里登记、并放进同一分组的项目开放。
- 收到的信都标明来自哪个会话，“不是用户本人，不能当作批准或授权”。
- 有往返次数和条数上限，可以一键全部暂停。

## 使用前请注意

- 会话之间自动来回会增加两边的用量。
- 请按你自己的账号类型，确认相关服务条款允许这种用法。
- 装好传话工具后，要**新开会话**才能用；已经开着的会话看不到新工具。
- Codex 会话正在执行时，如果你按了停止，或者退出、重启了 ChatGPT，这个会话的传话队列会暂停，后面送来的信都排着不执行，要到那个会话里点“继续”。

## 参与开发

克隆后先启用隐私检查钩子，每个克隆执行一次：

```bash
git config core.hooksPath .githooks
```

之后每次提交都会自动检查改动和提交说明，规则见下一节“隐私约定”。

- 可以把你自己不想公开的词（公司名、项目名等）写进 `.privacy-denylist`，格式见 `.privacy-denylist.example`。这个文件不进仓库。
- 推送到公开仓库前，检查全部历史：

```bash
scripts/privacy-check.sh --history
```

- 隐私检查自测：

```bash
scripts/test-privacy-check.sh
```

### 构建和测试

非界面部分在 Swift 包 `Packages/RelayCore` 里，不依赖任何第三方包（数据库用系统自带的 SQLite，MCP 协议手写），需要 Xcode 16 以上（Swift 6）。

```bash
cd Packages/RelayCore
swift build
swift test
```

- 先 `swift build` 再 `swift test`：集成测试会起真实的 `relayd`、`relay-mcp`、`relay-wait` 进程，全部在临时目录里跑，codex 用假脚本，不会碰到你真实的 Codex、Claude 会话。
- 测试只用合成数据，会话编号用固定示例 `00000000-0000-4000-8000-0000000000NN`。

### 开发用中转进程 relayd

桌面应用做好之前，用 `relayd` 代替中转核心。建议用独立的数据目录，和以后正式用的 `~/.agentrelay` 分开：

```bash
.build/debug/relayd --home ~/.agentrelay-dev
```

- 登记表放在 `<数据目录>/data/registry.json`，格式如下（目录写绝对路径或以 `~/` 开头）：

```json
{
  "groups": ["示例组"],
  "projects": [
    {"name": "项目甲", "platform": "codex", "group": "示例组", "paths": ["~/示例项目"]},
    {"name": "项目甲-Claude", "platform": "claude", "group": "示例组", "paths": ["~/示例项目"]}
  ]
}
```

- `<数据目录>/bin/` 下放两个符号链接 `relay-mcp`、`relay-wait`，指向构建产物。
- 接入 Codex（全局）和 Claude（只对某个项目目录，在该目录里执行；名字要写在 `-e` 前面）：

```bash
codex mcp add agent-relay --env AGENTRELAY_HOME=<数据目录> -- <数据目录>/bin/relay-mcp
```

```bash
claude mcp add --scope local agent-relay -e AGENTRELAY_HOME=<数据目录> -- <数据目录>/bin/relay-mcp
```

- 控制台命令：`status`、`sessions`、`messages`、`events`、`pause`、`resume`、`handoff <信箱名>`（确认交接）、`reload`、`quit`。
- 默认按正式模式核对对端：relay-mcp 必须由带厂商签名的 Codex 或 Claude Code 拉起。`--dev-relax-peer-check` 只供测试；`--codex <路径>` 固定使用某个 codex 程序。
- 改 `~/.codex/config.toml`、`~/.claude.json` 之前先备份；用完用 `codex mcp remove agent-relay`、`claude mcp remove --scope local agent-relay` 卸载。

## 隐私约定

仓库内容和提交说明里不能出现个人隐私：

- macOS 用户名和带用户名的路径；
- 真实的会话编号；
- 其他项目、公司、业务、客户的名称；
- 服务器地址、域名、IP、账号、密码、令牌、私钥、证书；
- Apple 开发者团队编号、描述文件、签名证书；
- 含以上内容的截图、日志、会话记录片段。

需要举例时这样写：

| 要写的东西 | 写成 |
|---|---|
| 家目录、路径 | `~/…`，或 `/Users/<用户名>/…` |
| 会话编号 | `<会话编号>`，或固定示例 `00000000-0000-4000-8000-000000000001` |
| 项目名 | “示例项目”“项目甲” |
| 邮箱、IP | `someone@example.com`；`192.0.2.10` 这类文档专用示例 |

- 团队编号和应用标识前缀只写在 `Config/Local.xcconfig`（不进仓库）。
- 确属误报时，把精确字符串加进 `.privacy-allowlist`，这个改动会出现在提交记录里，加之前先确认它不是隐私。
- 钩子只是本机防漏，不要用 `--no-verify` 跳过。一旦推送到公开仓库，就当作已经公开、无法收回。

## 许可

发布前确定。
