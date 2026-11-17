#!/usr/bin/env python3
"""给桌面端测试项目装上 / 卸下测试钩子（只写测试项目自己的 .codex/，不碰 ~/.codex）。

    python3 -I desktop_hooks_setup.py install   ~/relay-probe
    python3 -I desktop_hooks_setup.py uninstall ~/relay-probe

装上后要你本人在桌面端完成两件事，钩子才会运行：
1. 信任这个项目文件夹（项目里的钩子只在受信任的项目里加载）；
2. 在输入框的 Review hooks 或“设置 › Hooks”里审核并信任这三个钩子（PreToolUse、PostToolUse、Stop）。
脚本不会替你写任何信任记录。
"""
import json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
action, project = sys.argv[1], os.path.realpath(os.path.expanduser(sys.argv[2]))
dot = os.path.join(project, ".codex")
OWNED = ["hooks.json", "steer_hook.py", "steer-spool"]

if action == "install":
    if os.path.exists(os.path.join(dot, "hooks.json")):
        sys.exit("测试项目里已经有 .codex/hooks.json，不覆盖")
    os.makedirs(os.path.join(dot, "steer-spool"), exist_ok=True)
    shutil.copy(os.path.join(HERE, "steer_hook.py"), os.path.join(dot, "steer_hook.py"))
    hook = f"/usr/bin/python3 -I {dot}/steer_hook.py"
    spool = f"{dot}/steer-spool"
    with open(os.path.join(dot, "hooks.json"), "w") as f:
        json.dump({"description": "AgentRelay 调研测试用：把引导信注入当前轮次（测试完删除）",
                   "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": f"{hook} pre {spool}", "timeout": 10}]}],
                             "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": f"{hook} post {spool}", "timeout": 10}]}],
                             "Stop": [{"hooks": [{"type": "command", "command": f"{hook} stop {spool}", "timeout": 10}]}]}},
                  f, ensure_ascii=False, indent=1)
    print("已装上。请在桌面端信任项目文件夹和这三个钩子。")
elif action == "uninstall":
    for name in OWNED:
        p = os.path.join(dot, name)
        if os.path.isdir(p):
            shutil.rmtree(p)
        elif os.path.exists(p):
            os.remove(p)
    if os.path.isdir(dot) and not os.listdir(dot):
        os.rmdir(dot)
    print("已卸下。桌面端里的信任记录请在“设置 › Hooks”里自行处理。")
else:
    sys.exit("用法：desktop_hooks_setup.py install|uninstall <测试项目目录>")
