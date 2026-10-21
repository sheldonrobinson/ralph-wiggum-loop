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

## Install Skill (`.agents/skills/`)

Per the [Agent Skills Specification](https://agentskills.io/specification), install the skill to `.agents/skills/`:

```bash
# Project-level (.agents/skills/ralph-wiggum-loop) or User-level (~/.agents/skills/ralph-wiggum-loop)
mkdir -p .agents/skills
cp -R skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
```
```powershell
New-Item -ItemType Directory -Path .agents/skills -Force | Out-Null
Copy-Item -Recurse -Force skills/ralph-wiggum-loop .agents/skills/ralph-wiggum-loop
```

## OS-Specific MCP Servers (`mcp.json`)

| MCP Server Name | OS / Runtime | Transport | Command / Endpoint |
|---|---|---|---|
| `ralph-wiggum-loop` | Linux / macOS (Bash) | `stdio` | `./bin/script-runner.sh ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-pwsh` | Windows (PowerShell 7+) | `stdio` | `pwsh -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-powershell` | Windows (PowerShell 5.1) | `stdio` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 ralph-wiggum-loop --stdio` |
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
  ./bin/ralph-wiggum-loop.sh --stdio
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\ralph-wiggum-loop.ps1 --stdio
  ```

### 3. MCP Server (`streamable-http` Service Mode)
- **Linux / macOS (Bash):**
  ```bash
  ./bin/script-runner.sh start-http-server start --host 127.0.0.1 --port 8080
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server start --host 127.0.0.1 --port 8080
  ```

## Documentation

- [Skill & Agent Instructions](./.agents/skills/ralph-wiggum-loop/SKILL.md) — OS selection rules, loop execution modes, and Streamable HTTP setup
- [Full Documentation](./docs/README.md) — API reference, tools, state management
- [Deployment Guide](https://sheldonrobinson.github.io/ralph-wiggum-loop/deploy) — Install and configure

## Repository

- **Source:** <https://github.com/sheldonrobinson/ralph-wiggum-loop>
- **Agent Plugin Spec:** <https://agent-plugins.org>
- **MCP Spec:** <https://modelcontextprotocol.io>

## License

MIT
