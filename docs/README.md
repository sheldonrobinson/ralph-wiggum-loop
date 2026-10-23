---
layout: default
title: Documentation - ralph-wiggum-loop
---

# ralph-wiggum-loop

> **Multi-model iterative development agent plugin** — Ralph Loop with cross-model worker/reviewer architecture, Agent Skills (`.agents/skills/`), Stop hooks, and SHIP/REVISE decision engine.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Agent Plugin](https://img.shields.io/badge/Agent--Plugins-v1.0.0-blue)](https://agent-plugins.org)
[![Agent Skills](https://img.shields.io/badge/Agent--Skills-v1.0-green)](https://agentskills.io/specification)
[![GitHub Pages](https://github.com/sheldonrobinson/ralph-wiggum-loop/actions/workflows/pages.yml/badge.svg)](https://sheldonrobinson.github.io/ralph-wiggum-loop)

## Overview

The **Ralph Wiggum Loop** plugin implements an iterative development workflow combining:
1. **Multi-Model Worker/Reviewer Architecture:** A **Worker** model implements changes while an independent **Reviewer** model (from a different LLM provider/family) evaluates the submission and renders a **`SHIP`** or **`REVISE`** verdict.
2. **In-Session Self-Referential Stop Hooks:** A `Stop` hook intercepts session exit and re-feeds the prompt until `<promise>DONE</promise>` or `SHIP` is reached.
3. **Cross-Platform Polyglot Execution:** Native Bash (`bin/ralph-wiggum-loop.sh` + `bin/mcp-sdk.sh`) for Linux/macOS and PowerShell (`bin/ralph-wiggum-loop.ps1` + `bin/mcp-sdk.psm1`) for Windows, unified behind the polyglot `bin/script-runner`.

---

## Package Structure

```text
ralph-wiggum-loop/
+-- plugin.json                         # Agent Plugins v1.0.0 manifest
+-- mcp.json                            # MCP Server configurations (stdio & streamable-http)
+-- bin/
|   +-- script-runner                   # Polyglot runner (POSIX sh / Bash & PowerShell)
|   +-- script-runner.cmd               # Windows CMD launcher -> script-runner.ps1
|   +-- script-runner.sh                # Polyglot runner (.sh entry point)
|   +-- script-runner.ps1               # Polyglot runner (.ps1 entry point)
|   +-- mcp-sdk.sh                      # Generic Bash MCP SDK (stdio + streamable-http)
|   +-- mcp-sdk.psm1                    # Generic PowerShell MCP SDK (stdio + streamable-http)
|   +-- ralph-wiggum-loop.sh            # Bash MCP server & CLI loop runner
|   +-- ralph-wiggum-loop.ps1           # PowerShell MCP server & CLI loop runner
+-- .agents/skills/ralph-wiggum-loop/   # Canonical Agent Skills installation path
|   +-- SKILL.md                        # Skill metadata & instructions
|   +-- references/
|   |   +-- spec-template.md            # Feature specification template
|   |   +-- checklist.md                # Worker & Reviewer quality checklist
|   +-- scripts/
|       +-- setup-ralph-loop.{sh,ps1}   # Initialize .agents/ralph-loop.local.md
|       +-- start-http-server.{sh,ps1}  # Manage streamable-http MCP service
+-- skills/ralph-wiggum-loop/           # Agent Plugins v1.0.0 fixed skill discovery mirror
+-- io.github.sheldonrobinson.ralph-wiggum-loop/          # Client extension hooks & slash commands
|   +-- hooks/
|   |   +-- hooks.json
|   |   +-- stop-hook.{sh,ps1}
|   +-- commands/
|       +-- ralph-loop.md
|       +-- cancel-ralph.md
|       +-- help.md
+-- profiles/                           # Quality profiles (lite, plus, pro, super, ultra)
```

---

## MCP Servers (`mcp.json`)

| Server Key | Platform / Runtime | Transport | Command / Endpoint |
|---|---|---|---|
| `ralph-wiggum-loop` | Cross-Platform (`script-runner`) | `stdio` | `./bin/script-runner ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-sh` | Linux / macOS (Bash) | `stdio` | `./bin/script-runner.sh --use-sh ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-pwsh` | Windows (PowerShell 7+) | `stdio` | `pwsh -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-powershell` | Windows (PowerShell 5.1) | `stdio` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh ralph-wiggum-loop --stdio` |
| `ralph-wiggum-loop-http` | Cross-Platform | `streamable-http` | `http://127.0.0.1:8080/mcp` |

---

## MCP Tools Reference

| Tool Name | Required Arguments | Description |
|---|---|---|
| `ralph_loop_initialize` | `task`, `workerModel`, `workerProvider`, `reviewerModel`, `reviewerProvider` | Initialize a new Ralph Loop session |
| `ralph_loop_get_task` | *(optional `sessionId`)* | Retrieve the task description and guidelines for the Worker phase |
| `ralph_loop_submit_work` | `work`, `summary`, `iteration` | Submit Worker implementation and summary, transitioning to `REVIEW` |
| `ralph_loop_get_work` | *(optional `sessionId`)* | Retrieve submitted Worker output and summary for the Reviewer phase |
| `ralph_loop_submit_review` | `decision` (`SHIP` \| `REVISE`), `iteration` *(+ `feedback` if `REVISE`)* | Submit Reviewer verdict (`SHIP` completes session; `REVISE` advances iteration) |
| `ralph_loop_get_feedback` | *(optional `sessionId`)* | Retrieve Reviewer feedback for the next Worker iteration |
| `ralph_loop_get_status` | *(optional `sessionId`)* | Inspect current iteration, phase (`WORK`, `REVIEW`, `COMPLETE`), and status |
| `ralph_loop_get_config` | *(optional `sessionId`)* | Inspect configured Worker, Reviewer, and Monitor models/providers |
| `ralph_loop_reset` | *(optional `sessionId`)* | Clean up and delete session state |
| `ralph_loop_block` | `reason` | Mark the current iteration as blocked (`RALPH-BLOCKED.md`) |
| `ralph_loop_run` | `task`, `workerModel`, `workerProvider`, `reviewerModel`, `reviewerProvider` | Execute the complete automated Worker -> Reviewer -> Monitor loop |

---

## Polyglot Script Runner (`bin/script-runner`)

Both `bin/script-runner.sh` and `bin/script-runner.ps1` (and `bin/script-runner`) share identical polyglot source code that runs natively in both POSIX `sh`/`bash` and PowerShell:

```bash
# Run on Linux/macOS (or Git Bash):
./bin/script-runner.sh ralph-wiggum-loop --stdio
./bin/script-runner.sh setup-ralph-loop "Implement feature X" --max-iterations 10
./bin/script-runner.sh start-http-server start --host 127.0.0.1 --port 8080
./bin/script-runner.sh stop-hook
```

```powershell
# Run on Windows PowerShell:
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop --stdio
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 setup-ralph-loop "Implement feature X" --max-iterations 10
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server start --host 127.0.0.1 --port 8080
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 stop-hook
```

## Links

- [Deployment Guide](./deploy.md) — Full installation, MCP configuration, and Streamable HTTP service guide
- [Source Repository](https://github.com/sheldonrobinson/ralph-wiggum-loop)
- [Agent Plugins Specification](https://agent-plugins.org)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Model Context Protocol Specification](https://modelcontextprotocol.io)
