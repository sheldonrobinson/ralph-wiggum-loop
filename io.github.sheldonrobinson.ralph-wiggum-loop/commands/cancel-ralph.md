---
description: "Cancel active Ralph Wiggum loop, reset MCP session, or stop Streamable HTTP service"
---

# Cancel Ralph Loop

To cancel the active Ralph Wiggum loop based on the current operating system:

1. **In-Session Stop-Hook Loop (`.agents/ralph-loop.local.md`):**
   - **Linux / macOS (Bash):** Check `test -f .agents/ralph-loop.local.md`, read `iteration:`, and run `rm -f .agents/ralph-loop.local.md`.
   - **Windows (PowerShell):** Check `Test-Path .agents/ralph-loop.local.md`, read `iteration:`, and run `Remove-Item -Force .agents/ralph-loop.local.md -ErrorAction SilentlyContinue`.
2. **MCP Session State:**
   - If an MCP Ralph Loop session is active (`ralph-wiggum-loop` / `ralph-wiggum-loop-sh` on Linux/macOS or `ralph-wiggum-loop-pwsh` / `ralph-wiggum-loop-powershell` on Windows), call the `ralph_loop_reset` tool (with `sessionId`) to clean up session state.
3. **Streamable HTTP Service (Optional):**
   - **Linux / macOS:** `./bin/script-runner.sh start-http-server stop`
   - **Windows:** `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server stop`
