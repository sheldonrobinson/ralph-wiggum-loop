---
name: ralph-wiggum-loop
description: Autonomous iterative AI development with spec-driven execution, self-referential stop-hook loops, multi-model worker/reviewer SHIP/REVISE validation, and Streamable HTTP or stdio MCP server setup across Windows (PowerShell) and Linux/macOS (Bash). Use when implementing specs, fixing bugs, or iterating until acceptance criteria and tests pass.
license: MIT
compatibility: Windows requires PowerShell 5.1+ or pwsh 7+ and jq. Linux/macOS requires Bash 4+, jq, and socat or nc (for streamable-http).
metadata:
  author: sheldonrobinson
  version: "1.1.0"
  repository: https://github.com/sheldonrobinson/ralph-wiggum-loop
---

# Ralph Wiggum Loop

> Autonomous iterative AI coding combining Geoffrey Huntley's Ralph loop methodology, spec-driven development, in-session Stop hooks, and multi-model Worker/Reviewer verification across **Linux/macOS (Bash)** and **Windows (PowerShell)**.

## Installation (Canonical `.agents/skills/` Path)

Per the [Agent Skills Specification](https://agentskills.io/specification), install this skill to the canonical cross-client `.agents/skills/` directory so any Agent Skills-compatible client (Goose, VS Code Copilot, OpenAI Codex, Cursor, Claude Code, etc.) discovers it automatically:

- **Project-level install (`<project>/.agents/skills/ralph-wiggum-loop/`):**
  ```bash
  mkdir -p .agents/skills
  cp -R skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
  ```
  ```powershell
  New-Item -ItemType Directory -Path .agents/skills -Force | Out-Null
  Copy-Item -Recurse -Force skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
  ```
- **User-level install (`~/.agents/skills/ralph-wiggum-loop/`):**
  ```bash
  mkdir -p ~/.agents/skills
  cp -R skills/ralph-wiggum-loop ~/.agents/skills/ralph-wiggum-loop
  ```
- **Via Skill Installers (`npx skills` / `openskills`):**
  ```bash
  npx skills add sheldonrobinson/ralph-wiggum-loop
  ```

---

## 1. Platform Selection Rules (Windows vs. Linux/macOS)

The MCP server implementation and loop runner scripts are **OS-specific**:
- **Linux & macOS** use **Bash** (`./bin/ralph-wiggum-loop.sh` powered by `./bin/mcp-sdk.sh`).
- **Windows** uses **PowerShell** (`./bin/ralph-wiggum-loop.ps1` powered by `./bin/mcp-sdk.psm1`).
- **Polyglot Runner (`./bin/script-runner.sh` & `./bin/script-runner.ps1`):** A single polyglot script valid in both POSIX `sh`/`bash` and PowerShell that automatically dispatches to the right `.sh` or `.ps1` script for the host OS.

Before starting a loop, invoking CLI scripts, or starting the Streamable HTTP service, **detect the host operating system** and use the matching MCP server and script variant:

| Component | Linux / macOS (Bash) | Windows (PowerShell 7+ `pwsh`) | Windows (Windows PowerShell 5.1) |
|---|---|---|---|
| **MCP `stdio` Server (`mcp.json`)** | `ralph-wiggum-loop` | `ralph-wiggum-loop-pwsh` | `ralph-wiggum-loop-powershell` |
| **MCP `streamable-http` Server (`mcp.json`)** | `ralph-wiggum-loop-http` | `ralph-wiggum-loop-http` | `ralph-wiggum-loop-http` |
| **Polyglot Script Runner (`script-runner`)** | `./bin/script-runner.sh <target> [args...]` | `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 <target> [args...]` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 <target> [args...]` |
| **Loop Runner / MCP Entry Script** | `./bin/script-runner.sh ralph-wiggum-loop` | `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop` |
| **In-Session Loop Setup Script** | `scripts/setup-ralph-loop.sh` | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/setup-ralph-loop.ps1` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/setup-ralph-loop.ps1` |
| **Streamable HTTP Service Script** | `scripts/start-http-server.sh` | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/start-http-server.ps1` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/start-http-server.ps1` |
| **Session Stop Hook** | `./bin/script-runner.sh stop-hook` | `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 stop-hook` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 stop-hook` |

*(Per the Agent Skills specification, relative paths like `scripts/setup-ralph-loop.sh` and `references/spec-template.md` are resolved relative to the skill root `.agents/skills/ralph-wiggum-loop/` or `skills/ralph-wiggum-loop/`.)*

---

## 2. How the Agent Should Run the Ralph Loop

The agent can run the Ralph Loop in **three modes** depending on the task and environment:

### Mode A: Multi-Model Worker/Reviewer Loop via MCP Tools (Cross-Platform)
When connected to the active OS-appropriate MCP server (`ralph-wiggum-loop` on Linux/macOS, `ralph-wiggum-loop-pwsh` or `ralph-wiggum-loop-powershell` on Windows, or `ralph-wiggum-loop-http` over Streamable HTTP):

1. **Initialize (`ralph_loop_initialize`)**
   Initialize a session with `taskDescription`, `workerModel`, `workerProvider`, `reviewerModel`, `reviewerProvider`, `maxIterations`, and optional `profile` (`lite`, `plus`, `pro`, `super`, `ultra`).
2. **Work Phase (`ralph_loop_get_task` -> `ralph_loop_submit_work`)**
   Retrieve the current task and any prior reviewer feedback (`ralph_loop_get_feedback`), implement the changes, run all tests, and submit the work output and summary.
3. **Review Phase (`ralph_loop_get_work` -> `ralph_loop_submit_review`)**
   Inspect the submitted work against [references/checklist.md](references/checklist.md) and submit `SHIP` (when 100% complete) or `REVISE` with actionable file/line feedback.
4. **Full Automated Run (`ralph_loop_run`)**
   Or execute the complete automated Worker -> Reviewer -> Monitor loop in a single MCP tool call.

### Mode B: Automated CLI Loop Execution (OS-Specific)
To run the full multi-model loop directly from the shell:

- **Linux / macOS (Bash):**
  ```bash
  ./bin/script-runner.sh ralph-wiggum-loop "Implement spec from specs/auth/spec.md" \
    --profile pro \
    --max-iterations 10
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop `
    "Implement spec from specs/auth/spec.md" `
    --profile pro `
    --max-iterations 10
  ```
  *(If `pwsh` is not installed on Windows, replace `pwsh` with `powershell.exe`.)*

### Mode C: In-Session Self-Referential Stop-Hook Loop (OS-Specific)
To run an iterative loop inside the current agent session where the Stop hook blocks premature exit and re-feeds the prompt until `<promise>DONE</promise>` is output (state stored in `.agents/ralph-loop.local.md`):

- **Linux / macOS (Bash):**
  ```bash
  scripts/setup-ralph-loop.sh \
    "Implement feature X and pass all tests" \
    --max-iterations 20 \
    --completion-promise "DONE"
  ```
  To cancel: `rm -f .agents/ralph-loop.local.md`

- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/setup-ralph-loop.ps1 `
    "Implement feature X and pass all tests" `
    --max-iterations 20 \
    --completion-promise "DONE"
  ```
  To cancel: `Remove-Item -Force .agents/ralph-loop.local.md -ErrorAction SilentlyContinue`

---

## 3. Setting Up the `streamable-http` MCP Service

In `mcp.json`, the `ralph-wiggum-loop-http` server is configured to connect to:
```json
"ralph-wiggum-loop-http": {
  "type": "streamable-http",
  "url": "http://127.0.0.1:8080/mcp"
}
```
Unlike `stdio` servers (which the MCP client spawns automatically), a **`streamable-http` server runs as an independent HTTP service** that must be started before (or while) the agent connects to `http://127.0.0.1:8080/mcp`.

### 3.1 Windows Streamable HTTP Setup (PowerShell)
On Windows, `bin/mcp-sdk.psm1` uses `.NET`'s built-in `System.Net.HttpListener` to serve the MCP Streamable HTTP transport (`POST`, `GET` SSE `text/event-stream`, `DELETE`, `Mcp-Session-Id` session management, and `202 Accepted` on notifications). No external HTTP daemon is required.

1. **Start as a Background Service (Recommended):**
   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/start-http-server.ps1 start --host 127.0.0.1 --port 8080
   ```
   *(Or via the polyglot runner: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server start --host 127.0.0.1 --port 8080`)*

2. **Start in Foreground (Direct CLI):**
   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\ralph-wiggum-loop.ps1 --streamable-http --host 127.0.0.1 --port 8080
   ```

3. **Check Status / Ping Health Check:**
   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/start-http-server.ps1 status --host 127.0.0.1 --port 8080
   ```

4. **Stop the Service Cleanly:**
   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/start-http-server.ps1 stop --host 127.0.0.1 --port 8080
   ```

### 3.2 Linux / macOS Streamable HTTP Setup (Bash)
On Linux and macOS, `bin/mcp-sdk.sh` serves the MCP Streamable HTTP transport over TCP using `socat` (preferred, supports concurrent connections via `fork`) or `nc` (netcat).

1. **Prerequisites:**
   Ensure `jq` and `socat` (or `nc`) are installed:
   - macOS: `brew install jq socat`
   - Ubuntu/Debian: `sudo apt-get install -y jq socat`

2. **Start as a Background Daemon (Recommended):**
   ```bash
   scripts/start-http-server.sh start --host 127.0.0.1 --port 8080
   ```
   *(Or via the polyglot runner: `./bin/script-runner.sh start-http-server start --host 127.0.0.1 --port 8080`)*

3. **Start in Foreground (Direct CLI):**
   ```bash
   ./bin/ralph-wiggum-loop.sh --streamable-http --host 127.0.0.1 --port 8080 --listen
   ```

4. **Check Status:**
   ```bash
   scripts/start-http-server.sh status --host 127.0.0.1 --port 8080
   ```

5. **Stop the Service Cleanly:**
   ```bash
   scripts/start-http-server.sh stop
   ```

### 3.3 Streamable HTTP Environment Variables & Verification
Both the Bash and PowerShell Streamable HTTP servers recognize these environment variables:
- `MCP_TRANSPORT=streamable-http` — Selects Streamable HTTP transport mode
- `MCP_HTTP_HOST=127.0.0.1` — Bind IP address (use `127.0.0.1` or `localhost` per MCP security rules)
- `MCP_HTTP_PORT=8080` — TCP port (default: `8080`)
- `MCP_HTTP_ENDPOINT=/mcp` — HTTP path (default: `/mcp`)
- `RALPH_STATE_BASE` — Directory for persisting Ralph Loop session state (defaults to `${PLUGIN_DATA}/state` or `.ralph`)

To manually verify a running `streamable-http` server:
- **Bash (`curl`):**
  ```bash
  curl -i -X POST http://127.0.0.1:8080/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
  ```
- **PowerShell (`Invoke-RestMethod`):**
  ```powershell
  Invoke-RestMethod -Uri "http://127.0.0.1:8080/mcp" -Method Post -ContentType "application/json" `
    -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
  ```

---

## 4. Core Principles & Available MCP Tools

1. **Fresh Context & Shared State on Disk:** State persists in `.ralph/` or `${PLUGIN_DATA}/state`, `.agents/ralph-loop.local.md`, `specs/`, and git history.
2. **Backpressure via Tests & Cross-Model Review:** Automated tests, linters, and cross-model reviewer checks act as strict guardrails.
3. **Verifiable Completion Signal:** The loop terminates early only when the Reviewer submits `SHIP` (`ralph_loop_submit_review`) or the in-session agent outputs `<promise>DONE</promise>` after verifying all acceptance criteria.

### MCP Tools Reference
- `ralph_loop_initialize` - Initialize a new Ralph Loop session
- `ralph_loop_get_task` - Retrieve the task for the worker phase
- `ralph_loop_submit_work` - Submit worker implementation and summary
- `ralph_loop_get_work` - Retrieve submitted work for the reviewer phase
- `ralph_loop_submit_review` - Submit `SHIP` or `REVISE` review decision and feedback
- `ralph_loop_get_feedback` - Retrieve reviewer feedback for the next iteration
- `ralph_loop_get_status` - Inspect current session phase, iteration, and status
- `ralph_loop_get_config` - Inspect worker, reviewer, and monitor model configuration
- `ralph_loop_reset` - Reset and clean up session state
- `ralph_loop_block` - Mark the current iteration as blocked with a reason
- `ralph_loop_run` - Run the full automated multi-model loop

## Bundled Resources
- [references/spec-template.md](references/spec-template.md) - Specification template with acceptance criteria and testing backpressure checklist
- [references/checklist.md](references/checklist.md) - Quality & review checklist for validating specifications and worker submissions
- `scripts/setup-ralph-loop.sh` / `scripts/setup-ralph-loop.ps1` - Initialize an in-session stop-hook state file (`.agents/ralph-loop.local.md`)
- `scripts/start-http-server.sh` / `scripts/start-http-server.ps1` - Start, check status, or stop the `streamable-http` MCP server (`http://127.0.0.1:8080/mcp`)
