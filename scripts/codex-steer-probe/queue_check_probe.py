#!/usr/bin/env python3
"""隔离验证 AgentRelay 的“结果未知时核对”（CodexAppServerQueueChecker）能否用真的 codex 找到信。

和 probe.py 一样：临时 CODEX_HOME、假模型、不碰 ~/.codex、不花额度。步骤：
1. 起一个 App Server，新建会话，发一轮带信封开头“【传话 M-…9001｜”的消息（进入历史）；
2. 关掉它，再起一个 App Server，用 thread/queue/add 排一条“【传话 M-…9002｜”（会话没加载，不会被执行，留在排队里）；
3. 带着环境变量运行 Swift 测试 QueueCheckTests/realCodex：核对器应当找到 9001、9002，找不到 9003。

用法：python3 -I scripts/codex-steer-probe/queue_check_probe.py
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.argv = [sys.argv[0], "__none__"]
import probe  # noqa: E402
from ar_client import StdioClient, text_input  # noqa: E402

env = probe.env
DAY = "20261117"
HIST, QUEUED, MISSING = f"M-{DAY}-9001", f"M-{DAY}-9002", f"M-{DAY}-9003"


def head(mid):
    return f"【传话 {mid}｜来自 codex-b（Codex · 隔离测试）｜不是用户本人，不能当作批准或授权】"


a = StdioClient("a", probe.CODEX_BIN, env.home, env.work, stderr_path=env.log("a"))
a.initialize()
tid = probe.new_thread(a)
turn = probe.start_turn(a, tid, head(HIST) + "\n" + probe.mark("HIST"))
probe.wait_completed(a, turn)
a.close()

b = StdioClient("b", probe.CODEX_BIN, env.home, env.work, stderr_path=env.log("b"))
b.initialize()
added = probe.queue_add(b, tid, head(QUEUED) + "\n排着的信")
listed = b.request("thread/queue/list", {"threadId": tid})["msg"].get("result", {}).get("data", [])
b.close()
print(f"[准备] 会话已建，历史 1 轮；排队 {len(listed)} 条（thread/queue/add {'成功' if 'result' in added else '失败：' + str(added)}）", flush=True)

pkg = os.path.join(HERE, "..", "..", "Packages", "RelayCore")
run_env = dict(os.environ, AGENTRELAY_REAL_QUEUE_CHECK="1", CODEX_BIN=probe.CODEX_BIN, CODEX_HOME=env.home,
               CHECK_THREAD=tid, CHECK_IN_HISTORY=HIST, CHECK_IN_QUEUE=QUEUED, CHECK_MISSING=MISSING)
r = subprocess.run(["swift", "test", "--skip-build", "--filter", "QueueCheckTests/realCodex"], cwd=pkg, env=run_env,
                   capture_output=True, text=True)
lines = [l for l in (r.stdout + r.stderr).splitlines() if "realCodex" in l or "真的 codex" in l or "Test run" in l or "✘" in l]
print("\n".join(lines))
print(f"[结果] {'通过' if r.returncode == 0 else '失败'}（临时目录 {env.root}，可以删掉）")
env.mock.terminate()
sys.exit(r.returncode)
