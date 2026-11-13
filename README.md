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
- 在应用的“接入”页一键给 Codex、Claude 装上传话工具。它只用两边自己的官方命令（`codex mcp add`、`claude mcp add --scope user`），会改 `~/.codex/config.toml` 和 `~/.claude.json`；改之前先把这两个文件备份到本机的数据目录（只有你能读），每次改动都有记录。
- 两边都装在全局：所有 Codex、Claude 会话（包括开在 Git 工作副本里的）都能看到这个工具，但只有你登记过的项目里的会话调用才会成功；代价是每个会话都多一份工具说明。
- 撤回：在“接入”页点“卸载”；Codex 的配置装后没被别的程序改过时，会用备份逐字还原。要连应用一起卸掉，用“设置 › 完全卸载…”，它会先从两边移除，再删程序链接和运行文件，并问你要不要连数据库、备份和日志一起删。
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
- 接入向导的默认测试用模拟两边行为的假命令。要用真的 codex、claude 走一遍接入、核对、卸载，手动开启下面这项（需要装有 ChatGPT 桌面版和命令行 `claude`）。它把 `CODEX_HOME`、`CLAUDE_CONFIG_DIR` 指向临时目录，跑完核对你真实的配置没被改动：

```bash
AGENTRELAY_REAL_CLI_TEST=1 swift test --filter SetupTests
```

### 构建和运行桌面应用

桌面应用在 `App/`，工程是 `AgentRelay.xcodeproj`（需要 Xcode 16 以上，macOS 14 以上）。中转核心在应用里运行，菜单栏常驻；`relay-mcp`、`relay-wait` 两个命令行程序打进应用包的 `Contents/Helpers/`，应用启动时在数据目录的 `bin/` 下建指向它们的符号链接。

- **在 Xcode 里运行**：打开工程，选 `AgentRelay` 方案，点运行。共享的构建方案已带启动参数 `-AgentRelayHome ~/.agentrelay-dev`，开发数据和以后正式用的 `~/.agentrelay` 分开；菜单栏面板会显示“开发数据目录”。
- **命令行构建**（产物在 `build/`，不进仓库）：

```bash
xcodebuild -project AgentRelay.xcodeproj -scheme AgentRelay -configuration Debug -derivedDataPath build/DerivedData build
```

- **命令行运行**，同样带上开发数据目录：

```bash
build/DerivedData/Build/Products/Debug/AgentRelay.app/Contents/MacOS/AgentRelay -AgentRelayHome ~/.agentrelay-dev
```

- 不带这个参数打开开发构建（例如在访达里双击、用 `open`），会用正式的默认位置：`~/.agentrelay`、`~/Library/Application Support/AgentRelay`、`~/Library/Logs/AgentRelay`。环境变量 `AGENTRELAY_HOME` 的优先级高于启动参数。
- 同一个数据目录只能有一份 AgentRelay 在运行，再打开一份会提示“已经在运行”并退出。
- **签名**：没有 `Config/Local.xcconfig` 时，正式构建的应用标识是 `local.dev.AgentRelay`，按“仅在本机运行”签名，克隆下来就能构建。调试构建的标识是 `local.dev.AgentRelay.dev`，显示为“AgentRelay 开发版”：和正式版在系统里是两个应用，通知设置、登录项、偏好设置各自独立。要用自己的开发者团队签名，把 `Config/Local.xcconfig.example` 复制成 `Config/Local.xcconfig` 再填写；这个文件不进仓库。
- 界面文字目前只有中文，集中在 `App/Localizable.xcstrings`；Xcode 构建时会把新增的文字收进这个文件，改界面时随改动一起提交。
- 接入 Codex、Claude：在应用的“接入”页一键完成。数据目录不是默认位置时（例如开发数据目录），会把 `AGENTRELAY_HOME` 一并写进两边的配置。也可以按下一节手动接入。

### 开发时手动接入 Codex 和 Claude

一般用应用的“接入”页就行；用 relayd 或想手动操作时，把 `<数据目录>` 换成用的数据目录（例如 `~/.agentrelay-dev`）。两边都装在全局；Claude 那条的名字要写在 `-e` 前面：

```bash
codex mcp add agent-relay --env AGENTRELAY_HOME=<数据目录> -- <数据目录>/bin/relay-mcp
```

```bash
claude mcp add --scope user agent-relay -e AGENTRELAY_HOME=<数据目录> -- <数据目录>/bin/relay-mcp
```

- 改 `~/.codex/config.toml`、`~/.claude.json` 之前先备份；用完用 `codex mcp remove agent-relay`、`claude mcp remove --scope user agent-relay` 卸载。
- 装好后要新开会话才能用。Claude 会话登记后，按返回结果在后台运行等信命令。

### 开发用中转进程 relayd

`relayd` 是不带界面的命令行中转进程，集成测试用它，也可以在开发时代替桌面应用。和桌面应用一样，建议用独立的数据目录：

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

- relayd 不建链接：`<数据目录>/bin/` 下要自己放两个符号链接 `relay-mcp`、`relay-wait`，指向包的构建产物。接入两边的命令见上一节。
- 控制台命令：`status`、`sessions`、`messages`、`events`、`pause`、`resume`、`handoff <信箱名>`（确认交接）、`reload`、`quit`。
- 默认按正式模式核对对端：relay-mcp 必须由带厂商签名的 Codex 或 Claude Code 拉起。`--dev-relax-peer-check` 只供测试；`--codex <路径>` 固定使用某个 codex 程序。
- 同一个数据目录同时只能运行桌面应用和 relayd 中的一个。

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
