---
description: "Start Anvil Loop in current session"
argument-hint: "PROMPT [--max-iterations N] [--completion-promise TEXT]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-anvil-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Anvil Loop Command

Execute the setup script to initialize the Anvil loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-anvil-loop.sh" $ARGUMENTS
```

Please work on the task. When you try to exit, the Anvil loop will feed the SAME PROMPT back to you for the next iteration. You'll see your previous work in files and git history, allowing you to iterate and improve.

CRITICAL RULE: If a completion passphrase is set, you may ONLY output it on its own line when the statement is completely and unequivocally TRUE. The passphrase is auto-generated (ANVIL- prefix + hex hash from /dev/urandom) and shown in the setup output. Do not output false promises to escape the loop. The loop continues until genuine completion.
