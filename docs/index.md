---
layout: default
title: ralph-wiggum-loop
---

# ralph-wiggum-loop

> Multi-model iterative development agent plugin — Ralph Loop with cross-model worker/reviewer architecture, Agent Skills (`.agents/skills/`), Stop hooks, and SHIP/REVISE decision engine.

[Read the Full Documentation ->](./README.md) | [Deployment Guide ->](./deploy/)

## What is the Ralph Loop?

A two-phase iterative workflow where a **worker** model implements the task and an independent **reviewer** model provides cross-model verification, iterating until the reviewer issues **"SHIP"** (or `<promise>DONE</promise>` in in-session Stop-hook mode).

```text
+----------+      WORK PHASE       +----------+
|   TASK   | --------------------> |  WORKER  |
|  / SPEC  |     fresh context     | (Model A)|
+----------+                       +-----+----+
                                         |
                                         v
                           +--------------------+
                           |   Submit Work +    |
                           |      Summary       |
                           +---------+----------+
                                     |
                                     v
+----------+     REVIEW PHASE      +----------+
| REVIEWER | <-------------------- |   WORK   |
| (Model B)|   cross-model review  |  OUTPUT  |
+----+-----+                       +----------+
     |
     v
+----------+
| DECISION | ------> SHIP (Complete)
|          | ------> REVISE (Next Iteration)
+----------+
```

## Key Features

- **Agent Plugins v1.0.0 & Agent Skills Compliant**: Root `plugin.json`, `mcp.json`, and canonical `.agents/skills/ralph-wiggum-loop/` skill layout.
- **Cross-Platform Polyglot Script Runner (`bin/script-runner`)**: Single polyglot runner valid in both POSIX `sh`/`bash` and PowerShell (`pwsh` / `powershell.exe`) that automatically dispatches to `.sh` on Linux/macOS and `.ps1` on Windows.
- **Generic `shebang-mcp-sdk` (`bin/mcp-sdk.sh` & `bin/mcp-sdk.psm1`)**: Full JSON-RPC 2.0 MCP implementation supporting both **`stdio`** and **`streamable-http`** (`POST`, `GET` SSE `text/event-stream`, `DELETE`, `Mcp-Session-Id`) transports with deterministic on-exit cleanup handlers.
- **11 MCP Tools**: Complete workflow control (`ralph_loop_initialize`, `ralph_loop_get_task`, `ralph_loop_submit_work`, `ralph_loop_get_work`, `ralph_loop_submit_review`, `ralph_loop_get_feedback`, `ralph_loop_get_status`, `ralph_loop_get_config`, `ralph_loop_reset`, `ralph_loop_block`, and `ralph_loop_run`).
- **In-Session Stop Hooks (`io.github.sheldonrobinson.ralph-wiggum-loop/hooks/`)**: Cross-platform `stop-hook.sh` and `stop-hook.ps1` that block premature session exit until `<promise>DONE</promise>` or `SHIP` is reached.
- **5 Quality Profiles**: `lite`, `plus`, `pro`, `super`, `ultra` with adaptive profile switching and rate-limit backoff.

## Quick Start

### 1. Install Skill to `.agents/skills/`
```bash
# Linux / macOS
mkdir -p .agents/skills
cp -R skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
```
```powershell
# Windows (PowerShell)
New-Item -ItemType Directory -Path .agents/skills -Force | Out-Null
Copy-Item -Recurse -Force skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
```

### 2. Run via Polyglot Script Runner
```bash
# Linux / macOS (Bash)
./bin/script-runner.sh ralph-wiggum-loop "Implement user authentication with JWT tokens" --profile pro

# Or start MCP Server (stdio)
./bin/script-runner.sh ralph-wiggum-loop --stdio

# Or start Streamable HTTP Service (http://127.0.0.1:8080/mcp)
./bin/script-runner.sh start-http-server start --host 127.0.0.1 --port 8080
```

```powershell
# Windows (PowerShell)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop "Implement user authentication with JWT tokens" --profile pro

# Or start MCP Server (stdio)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop --stdio

# Or start Streamable HTTP Service (http://127.0.0.1:8080/mcp)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server start --host 127.0.0.1 --port 8080
```

## Documentation

- [Full Reference (`docs/README.md`)](./README.md) — Architecture, MCP tools, polyglot runner, and state management
- [Deployment Guide (`/deploy/`)](./deploy/) — Installation, `mcp.json` configuration, and Streamable HTTP setup

## Repository & Specifications

- **Source:** [github.com/sheldonrobinson/ralph-wiggum-loop](https://github.com/sheldonrobinson/ralph-wiggum-loop)
- **Agent Plugins Spec:** [agent-plugins.org](https://agent-plugins.org)
- **Agent Skills Spec:** [agentskills.io/specification](https://agentskills.io/specification)
- **MCP Spec:** [modelcontextprotocol.io](https://modelcontextprotocol.io)

## License

MIT
