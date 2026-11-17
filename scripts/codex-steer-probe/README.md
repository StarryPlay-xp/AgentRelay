# Codex 引导（steer）/ 排队（queue）隔离测试脚本

验证 Codex App Server 的 `turn/steer`、`thread/queue/*`，以及用官方钩子（`PreToolUse`、`PostToolUse`、`Stop`）把信注入正在进行的轮次。

**`probe.py`、`hook_probe.py` 是隔离测试，只证明协议机制，不代表已经接通 Codex 桌面端正在运行的会话；桌面端测试见最后一节。**

## 安全边界

- 每次运行在 `/tmp/ars*` 下新建临时目录，`CODEX_HOME` 指向它；不读写 `~/.codex`，不需要登录，不花额度。
- 模型换成 `mock_model.py`：只监听 `127.0.0.1`，按约定的关键字回固定文字或让 Codex 执行 `sleep N`。
- 唯一会真正执行的命令是 `sleep N`；审批用例里的 `echo approved-run` 会被测试脚本拒绝，不会执行。
- 默认使用 ChatGPT 自带的 codex（和桌面端同一版本）；可用环境变量 `CODEX_BIN` 换成别的。

## 文件

| 文件 | 作用 |
|---|---|
| `mock_model.py` | 假的 Responses 接口（SSE）。请求头 `x-codex-turn-metadata` 里的 `turn_id` 用来证明“在同一轮次里读到” |
| `ar_client.py` | 最小 App Server 客户端：stdio，或 unix 套接字上的 WebSocket（桌面端连共享服务时用的就是这种） |
| `probe.py` | `turn/steer`、`thread/queue/*`、`turn/start`、多连接、断线、审批、停止、另起实例等用例 |
| `steer_hook.py` | 测试用钩子：从信件目录认领“引导信”。`PreToolUse` 拒绝即将执行的命令并把信作为理由，`PostToolUse` 用 `additionalContext` 注入，`Stop` 用 `decision=block` 续上本轮 |
| `hook_probe.py` | 钩子路线的用例（含“未信任的钩子不运行”对照、命令执行前拦截 P1/P2） |
| `queue_check_probe.py` | 用真的 codex 验证 AgentRelay 的“结果未知时核对”：准备一个有历史、有排队的会话，再运行手动开启的 Swift 测试 `QueueCheckTests/realCodex`（要先在 `Packages/RelayCore` 里 `swift build --build-tests`） |
| `desktop_hooks_setup.py` | 第三阶段：给桌面端**测试项目**装上 / 卸下测试钩子（只写测试项目的 `.codex/`） |
| `desktop_watch.py`、`desktop_watch_d.py`、`desktop_watch_e.py` | 第三阶段：只读观察桌面端测试会话的记录，按阶段自动排队或放引导信，报告落在哪一轮 |

## 运行

```bash
python3 -I scripts/codex-steer-probe/probe.py
```

```bash
python3 -I scripts/codex-steer-probe/probe.py T1 T6b
```

```bash
python3 -I scripts/codex-steer-probe/hook_probe.py
```

```bash
python3 -I scripts/codex-steer-probe/queue_check_probe.py
```

- `probe.py` 全部跑完约 4 分钟，`hook_probe.py` 约 1 分钟。
- 结果逐行打印 `[PASS]`/`[FAIL]`/`[INFO]`，并写入临时目录里的 `report.json` / `hook-report.json`。`INFO` 表示记录行为、不判对错（例如“重复提交是否去重”）。
- 跑完可以删掉 `/tmp/ars*`。

## 第三阶段：桌面端专用测试会话

**只在你专门新建的测试会话里做，不要对真实工作的会话运行。** 会往测试会话排真实的信，会花一点额度。

1. 新建一个空文件夹作为测试项目（下面用 `~/relay-probe`），装上测试钩子：

```bash
python3 -I scripts/codex-steer-probe/desktop_hooks_setup.py install ~/relay-probe
```

2. 在 ChatGPT 的 Codex 里对这个文件夹新建对话，信任文件夹；在 Review hooks 或“设置 › Hooks”里信任三个钩子；让它运行一次 `echo hello`。
3. 找到测试会话编号的末几位（`~/relay-probe/.codex/steer-spool/hook-log.jsonl` 里的 `session`），启动观察，再按提示在测试会话里依次发含 DONE-A、DONE-B、DONE-C 的任务（每段等回复完再发下一段；B 段看到“待处理”后按停止）：

```bash
python3 -I scripts/codex-steer-probe/desktop_watch.py <会话编号末几位>
```

4. 可选 D 段（结束钩子）、E 段（命令执行前拦截），各自的任务文字写在脚本开头：

```bash
python3 -I scripts/codex-steer-probe/desktop_watch_d.py <会话编号末几位>
```

```bash
python3 -I scripts/codex-steer-probe/desktop_watch_e.py <会话编号末几位>
```

5. 收尾：

```bash
python3 -I scripts/codex-steer-probe/desktop_hooks_setup.py uninstall ~/relay-probe
```

桌面端里的文件夹信任和钩子信任记录由你在界面里自行处理；脚本不读写 `~/.codex/config.toml`。
