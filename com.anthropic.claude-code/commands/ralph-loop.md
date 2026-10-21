---
description: "Start a Ralph Wiggum iterative loop in the current session (Linux/macOS Bash or Windows PowerShell)"
argument-hint: "PROMPT [--max-iterations N] [--completion-promise TEXT]"
allowed-tools: ["Bash(${PLUGIN_ROOT}/bin/script-runner.sh:*)", "Bash(pwsh -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1:*)", "Bash(powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1:*)"]
hide-from-slash-command-tool: "true"
---

# Ralph Loop Command

## Step 1: Select OS-Specific Runner & MCP Server

The Ralph Wiggum Loop uses **Bash on Linux/macOS** and **PowerShell on Windows** (installed under `.agents/skills/ralph-wiggum-loop/` or `skills/ralph-wiggum-loop/`):

- **Linux / macOS (Bash):**
  - Initialize in-session state (`.agents/ralph-loop.local.md`):
    ```bash
    "${PLUGIN_ROOT}/bin/script-runner.sh" setup-ralph-loop $ARGUMENTS
    ```
  - Or run the full multi-model loop via CLI:
    ```bash
    "${PLUGIN_ROOT}/bin/script-runner.sh" ralph-wiggum-loop $ARGUMENTS
    ```
  - MCP Server (`mcp.json`): Use `ralph-wiggum-loop` (`stdio`) or `ralph-wiggum-loop-http` (`streamable-http`).

- **Windows (PowerShell):**
  - Initialize in-session state (`.agents/ralph-loop.local.md`):
    ```powershell
    pwsh -NoProfile -ExecutionPolicy Bypass -File "${PLUGIN_ROOT}/bin/script-runner.ps1" setup-ralph-loop $ARGUMENTS
    ```
    *(If `pwsh` is unavailable, use `powershell.exe`.)*
  - Or run the full multi-model loop via CLI:
    ```powershell
    pwsh -NoProfile -ExecutionPolicy Bypass -File "${PLUGIN_ROOT}/bin/script-runner.ps1" ralph-wiggum-loop $ARGUMENTS
    ```
  - MCP Server (`mcp.json`): Use `ralph-wiggum-loop-pwsh` (PowerShell 7+), `ralph-wiggum-loop-powershell` (Windows PowerShell 5.1), or `ralph-wiggum-loop-http` (`streamable-http`).

## Step 2: Iterate Until Verifiable Completion

1. Implement the required changes and verify all acceptance criteria.
2. Run automated tests and linters to create backpressure.
3. If using the MCP multi-model review flow, submit your work with `ralph_loop_submit_work` and inspect Reviewer feedback via `ralph_loop_get_feedback`.
4. When you attempt to exit, the Stop hook will feed the prompt back for the next iteration until completion.

CRITICAL RULE: If a completion promise (`<promise>...</promise>`) is configured, ONLY output it when every acceptance criterion and test requirement is 100% satisfied.
