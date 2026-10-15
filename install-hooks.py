#!/usr/bin/env python3
"""Wire Claude Code to Ada: hooks for every session event.

  ./install-hooks.py              install (safe to re-run)
  ./install-hooks.py --uninstall  remove Ada hooks

~/.claude/settings.json is backed up to settings.json.bak-ada before it is changed.
"""
import json, os, shutil, sys

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
ADA = os.path.join(HOME, ".ada")
HOOK = os.path.join(ADA, "hook.sh")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification",
          "PreCompact", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"]
MATCHED = {"PreToolUse", "PostToolUse", "PermissionRequest", "Notification"}


def ours(cmd):
    return HOOK in cmd  # our entries get removed before (re)installing


def main():
    uninstall = "--uninstall" in sys.argv
    if not uninstall:
        os.makedirs(ADA, mode=0o700, exist_ok=True)
        shutil.copy(os.path.join(HERE, "hook.sh"), HOOK)
        os.chmod(HOOK, 0o755)

    cfg = json.load(open(SETTINGS)) if os.path.exists(SETTINGS) else {}
    if os.path.exists(SETTINGS):
        shutil.copy(SETTINGS, SETTINGS + ".bak-ada")

    hooks = cfg.setdefault("hooks", {})
    for event in list(hooks):
        groups = []
        for g in hooks[event]:
            g["hooks"] = [h for h in g.get("hooks", []) if not ours(h.get("command", ""))]
            if g["hooks"]:
                groups.append(g)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]

    if not uninstall:
        for e in EVENTS:
            h = {"type": "command", "command": f"'{HOOK}'"}
            if e == "PermissionRequest":
                h["timeout"] = 86400  # the hook waits until you click on the island
            group = {"hooks": [h]}
            if e in MATCHED:
                group["matcher"] = "*"
            hooks.setdefault(e, []).append(group)

    if not hooks:
        del cfg["hooks"]
    with open(SETTINGS, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print(("removed from " if uninstall else "installed in ") + SETTINGS)


if __name__ == "__main__":
    main()
