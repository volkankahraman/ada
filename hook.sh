#!/bin/sh
# Claude Code hook: forwards the event JSON to Ada and prints Ada's answer.
# If Ada is not running, curl fails fast and the agent continues as if no hook existed.
curl -s -m 86400 --unix-socket "$HOME/.ada/ada.sock" \
  -H "Expect:" -H "X-Bundle: $__CFBundleIdentifier" \
  -H "X-Host-Session: $CLAUDE_CODE_HOST_SESSION_ID" \
  --data-binary @- http://ada/hook 2>/dev/null
exit 0
