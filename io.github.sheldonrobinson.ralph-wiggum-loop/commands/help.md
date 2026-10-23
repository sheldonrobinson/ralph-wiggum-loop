---
description: "Explain the Ralph Wiggum Loop plugin, OS-specific MCP servers, Agent Skills (.agents/skills/), hooks, and Streamable HTTP setup"
---

# Ralph Wiggum Loop Plugin Help

Explain the **Ralph Wiggum Loop** plugin capabilities and OS-specific execution rules to the user:

1. **Agent Skills Location (`.agents/skills/ralph-wiggum-loop/`)**:
   - Conforms to the [Agent Skills Specification](https://agentskills.io/specification).
   - Installed at `<project>/.agents/skills/ralph-wiggum-loop/` (or `~/.agents/skills/ralph-wiggum-loop/`) for cross-client discovery, and bundled at `skills/ralph-wiggum-loop/` for Agent Plugins v1.0.0 discovery.

2. **OS-Specific MCP Servers (`mcp.json`)**:
   - **Linux / macOS (Bash):** `ralph-wiggum-loop` (`./bin/script-runner.sh ralph-wiggum-loop --stdio`)
   - **Windows (PowerShell 7+):** `ralph-wiggum-loop-pwsh` (`pwsh -File ${PLUGIN_ROOT}/bin/script-runner.ps1 ralph-wiggum-loop --stdio`)
   - **Windows (Windows PowerShell 5.1):** `ralph-wiggum-loop-powershell` (`powershell.exe -File ${PLUGIN_ROOT}/bin/script-runner.ps1 ralph-wiggum-loop --stdio`)
   - **Streamable HTTP (Cross-Platform):** `ralph-wiggum-loop-http` (`http://127.0.0.1:8080/mcp`)

3. **Starting the `streamable-http` Service**:
   - **Linux / macOS (Bash):**
     `./bin/script-runner.sh start-http-server start --host 127.0.0.1 --port 8080`
     *(or `.agents/skills/ralph-wiggum-loop/scripts/start-http-server.sh start --host 127.0.0.1 --port 8080`)*
   - **Windows (PowerShell):**
     `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server start --host 127.0.0.1 --port 8080`
     *(or `pwsh -NoProfile -ExecutionPolicy Bypass -File .\.agents\skills\ralph-wiggum-loop\scripts\start-http-server.ps1 start --host 127.0.0.1 --port 8080`)*

4. **Running the Loop**:
   - **MCP Tools:** `ralph_loop_initialize`, `ralph_loop_get_task`, `ralph_loop_submit_work`, `ralph_loop_get_work`, `ralph_loop_submit_review`, `ralph_loop_get_feedback`, and `ralph_loop_run`.
   - **CLI Mode:**
     - Linux/macOS: `./bin/script-runner.sh ralph-wiggum-loop "<task>" --profile pro`
     - Windows: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop "<task>" --profile pro`
   - **In-Session Stop Hook Mode (`.agents/ralph-loop.local.md`):**
     - Linux/macOS: `./bin/script-runner.sh setup-ralph-loop "<task>" --max-iterations 20 --completion-promise "DONE"`
     - Windows: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 setup-ralph-loop "<task>" --max-iterations 20 --completion-promise "DONE"`
