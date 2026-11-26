# ralph-wiggum-loop

> **Multi-model iterative development agent plugin** — Ralph Loop with cross-model worker/reviewer architecture, spec-driven development skills, Stop hooks, and SHIP/REVISE decision engine.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Agent Plugin](https://img.shields.io/badge/Agent--Plugins-v1.0.0-blue)](https://agent-plugins.org)
[![GitHub Pages](https://github.com/sheldonrobinson/ralph-wiggum-loop/actions/workflows/pages.yml/badge.svg)](https://sheldonrobinson.github.io/ralph-wiggum-loop)

## Overview

The Ralph Loop implements a two-phase iterative workflow where a **worker** model does the work and a **reviewer** model provides cross-model review, iterating until the reviewer says **"SHIP"**.

This project is a **cross-platform Agent Plugin** (`plugin.json`, `mcp.json`, `.agents/skills/ralph-wiggum-loop/` & `skills/ralph-wiggum-loop/`) with native implementations for:
- **Linux / macOS (Bash):** `bin/ralph-wiggum-loop.sh` (using `bin/mcp-sdk.sh`)
- **Windows (PowerShell):** `bin/ralph-wiggum-loop.ps1` (using `bin/mcp-sdk.psm1`)
- **Polyglot Runner:** `bin/script-runner.sh` / `bin/script-runner.ps1` (runs in both POSIX `sh`/`bash` and PowerShell)

## Prerequisites

- **All platforms:** [`jq`](https://jqlang.org/) must be installed and available on `PATH`. The Bash CLI, MCP server, and packaging script use it for JSON processing. The PowerShell implementation also uses `jq`: it is registered in `$script:SafeCommands` in `bin/ralph-wiggum-loop.ps1` as an allowed command for loop operations. PowerShell's MCP JSON-RPC transport itself is implemented in PowerShell.
- **Linux / macOS / WSL (Bash):** Bash is required. When using WSL, install `jq` inside the WSL distribution.
- **Windows (PowerShell):** Windows PowerShell 5.1 or PowerShell 7+ (`pwsh`) and `jq` are required.
- **Bash `streamable-http` mode:** `socat` or `nc` must also be installed. The PowerShell HTTP service uses the built-in .NET `HttpListener` instead.
- **Running worker/reviewer loops:** At least one supported LLM CLI must be installed and configured. This is not needed merely to start the MCP server or list its tools.

Install `jq` using your platform's package manager:

```bash
# Ubuntu / Debian / WSL
sudo apt update && sudo apt install -y jq

# macOS
brew install jq
```

```powershell
# Windows (PowerShell)
# For WSL, use the WSL installation command above instead.
winget install jqlang.jq
```

Verify that the CLI and server can find it:

```bash
# Bash
command -v jq
jq --version
```

```powershell
# PowerShell
Get-Command jq
jq --version
```

## Install on Windows (PowerShell)

From the repository root, run the native PowerShell installer:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

This installs the complete plugin and the canonical Agent Skill to:

```text
$HOME\.agents\ralph-wiggum-loop\
$HOME\.agents\skills\ralph-wiggum-loop\
```

The installer uses only PowerShell file operations; no deployment module is required. Run the same command again to update an installation. The `bin`, `profiles`, embedded skill, canonical skill, and hooks/commands directories are mirrored, so stale files in those managed directories are removed.

Use `-AgentsRoot` to install both destinations below a different base directory:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AgentsRoot C:\Temp\ralph-agents
```

For independent destinations, use `-PluginRoot` and `-SkillRoot` together:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -PluginRoot D:\AgentPlugins\ralph-wiggum-loop `
  -SkillRoot D:\AgentSkills\ralph-wiggum-loop
```

After installation, use `$HOME\.agents\ralph-wiggum-loop` as `<install-folder>` in the MCP commands below, or substitute your custom plugin destination.

## Install Only the Agent Skill (`.agents/skills/`)

Per the [Agent Skills Specification](https://agentskills.io/specification), install just the skill to `.agents/skills/`:

```bash
# Project-level (.agents/skills/ralph-wiggum-loop) or User-level (~/.agents/skills/ralph-wiggum-loop)
mkdir -p .agents/skills
cp -R skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
```
```powershell
New-Item -ItemType Directory -Path .agents/skills -Force | Out-Null
Copy-Item -Recurse -Force skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
```
[![Ralph Wiggum Loop MCP server](https://mcprush.com/badge/ralph-wiggum-loop-mcp/card.svg)](https://mcprush.com/to/ralph-wiggum-loop-mcp?ref=badge)

## OS-Specific MCP Servers (`mcp.json`)

| MCP Server Name | OS / Runtime | Transport | Command / Endpoint |
|---|---|---|---|
| `ralph-wiggum-loop` | Linux / macOS (Bash) | `stdio` | `./bin/script-runner ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-sh` | Linux / macOS (POSIX `sh` wrapper) | `stdio` | `sh ${PLUGIN_ROOT}/bin/script-runner.sh --use-sh ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-pwsh` | Windows (PowerShell 7+) | `stdio` | `pwsh -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-powershell` | Windows (PowerShell 5.1) | `stdio` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-http` | Cross-Platform | `streamable-http` | `http://127.0.0.1:8080/mcp` |

## Quick Start

### 1. CLI Mode
- **Linux / macOS (Bash):**
  ```bash
  ./bin/ralph-wiggum-loop.sh "Implement user authentication with JWT tokens" --profile pro
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\ralph-wiggum-loop.ps1 "Implement user authentication with JWT tokens" --profile pro
  ```

### 2. MCP Server (`stdio` Mode)
- **Linux / macOS (Bash):**
  ```bash
  ./bin/script-runner.sh ralph-wiggum-loop --stdio
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File "<install-folder>\bin\script-runner.ps1" --use-pwsh ralph-wiggum-loop --stdio
  ```

> Use `--stdio` exactly (not `-Stdio`). MCP stdio is a persistent JSON-RPC channel: the client keeps stdin open while sending requests, and the server streams responses without waiting for EOF. Closing stdin ends the server session. Both Bash and PowerShell environments require `jq` on `PATH` as described in [Prerequisites](#prerequisites).

### 3. MCP Server (`streamable-http` Service Mode)
- **Linux / macOS (Bash):**
  ```bash
  ./bin/script-runner.sh start-http-server start --host 127.0.0.1 --port 8080
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server start --host 127.0.0.1 --port 8080
  ```

**Verify the server is responding:**
```bash
# Check status
./bin/script-runner.sh start-http-server status --host 127.0.0.1 --port 8080

# List available tools (POST to the MCP endpoint)
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -H "mcp-session-id: test-session" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

**Stop the server:**
```bash
./bin/script-runner.sh start-http-server stop --host 127.0.0.1 --port 8080
```

> **Port conflict:** If port `8080` is already in use by another process, the server will fail to bind. Check with `netstat -ano | findstr :8080` (Windows) or `lsof -i :8080` (Linux/macOS), then either free the port or use a different one (`--port 8081`).

## Documentation

- [Skill & Agent Instructions](./skills/ralph-wiggum-loop/SKILL.md) — OS selection rules, loop execution modes, and Streamable HTTP setup
- [Full Documentation](./docs/README.md) — API reference, tools, state management
- [Deployment Guide](https://sheldonrobinson.github.io/ralph-wiggum-loop/deploy) — Install and configure

## Repository

- **Source:** <https://github.com/sheldonrobinson/ralph-wiggum-loop>
- **Agent Plugin Spec:** <https://agent-plugins.org>
- **MCP Spec:** <https://modelcontextprotocol.io>

## License

MIT
