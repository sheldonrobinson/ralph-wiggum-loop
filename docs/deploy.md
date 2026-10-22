---
layout: default
title: Deployment Guide - ralph-wiggum-loop
permalink: /deploy/
---

# Deployment Guide

## 1. Install from Source

```bash
git clone https://github.com/sheldonrobinson/ralph-wiggum-loop
cd ralph-wiggum-loop
chmod +x bin/ralph-wiggum-loop.sh bin/script-runner.sh bin/script-runner
```

### Install Agent Skill to `.agents/skills/`

Per the [Agent Skills Specification](https://agentskills.io/specification), install the skill to `.agents/skills/` (project-level `<project>/.agents/skills/ralph-wiggum-loop` or user-level `~/.agents/skills/ralph-wiggum-loop`):

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

---

## 2. Configure as MCP Server (`mcp.json`)

The plugin includes `mcp.json` conforming to the Agent Plugins v1.0.0 specification (`https://agent-plugins.org/schemas/1.0.0/mcp.schema.json`) using the polyglot `script-runner`:

- **Universal (`stdio`):** `ralph-wiggum-loop` (`./bin/script-runner`)
- **Linux / macOS (Bash `stdio`):** `ralph-wiggum-loop-sh` (`./bin/script-runner.sh --use-sh`)
- **Windows (PowerShell 7+ `stdio`):** `ralph-wiggum-loop-pwsh` (`pwsh -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh`)
- **Windows (Windows PowerShell 5.1 `stdio`):** `ralph-wiggum-loop-powershell` (`powershell.exe -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh`)
- **Streamable HTTP (`http://127.0.0.1:8080/mcp`):** `ralph-wiggum-loop-http`

### Linux / macOS (`stdio`)
```json
{
  "mcpServers": {
    "ralph-wiggum-loop-sh": {
      "type": "stdio",
      "command": "./bin/script-runner.sh",
      "args": ["--use-sh", "ralph-wiggum-loop", "--stdio"],
      "cwd": "${PLUGIN_ROOT}",
      "env": {
        "RALPH_STATE_BASE": "${PLUGIN_DATA}/state",
        "RALPH_RECIPE_DIR": "${PLUGIN_ROOT}/recipes"
      }
    }
  }
}
```

### Windows — PowerShell (`stdio`)
```json
{
  "mcpServers": {
    "ralph-wiggum-loop-pwsh": {
      "type": "stdio",
      "command": "pwsh",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${PLUGIN_ROOT}/bin/script-runner.ps1",
        "--use-pwsh",
        "ralph-wiggum-loop",
        "--stdio"
      ],
      "cwd": "${PLUGIN_ROOT}",
      "env": {
        "RALPH_STATE_BASE": "${PLUGIN_DATA}/state",
        "RALPH_RECIPE_DIR": "${PLUGIN_ROOT}/recipes"
      }
    }
  }
}
```
*(Use `"command": "powershell.exe"` on Windows PowerShell 5.1.)*

---

## 3. Streamable HTTP Service (`streamable-http`)

To use the `ralph-wiggum-loop-http` entry (`http://127.0.0.1:8080/mcp`), start the HTTP service for your OS using `script-runner`:

- **Linux / macOS (Bash — requires `jq` and `socat` or `nc`):**
  ```bash
  # Start background service
  ./bin/script-runner.sh start-http-server start --host 127.0.0.1 --port 8080

  # Check status / Stop service
  ./bin/script-runner.sh start-http-server status
  ./bin/script-runner.sh start-http-server stop
  ```

- **Windows (PowerShell — uses built-in `.NET HttpListener`):**
  ```powershell
  # Start background service
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server start --host 127.0.0.1 --port 8080

  # Check status / Stop service
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server status
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 start-http-server stop
  ```

---

## 4. Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPH_WORKER_MODEL` | `-` | Worker LLM model name (e.g., `claude-3-5-sonnet`, `gpt-4o`) |
| `RALPH_WORKER_PROVIDER` | `-` | Worker provider (`anthropic`, `openai`, `google`, `copilot`, `goose`, `nvidia`) |
| `RALPH_WORKER_AGENT` | `goose` | Worker agent |
| `RALPH_REVIEWER_MODEL` | `-` | Reviewer LLM model name |
| `RALPH_REVIEWER_PROVIDER` | `-` | Reviewer provider |
| `RALPH_REVIEWER_AGENT` | `goose` | Reviewer agent |
| `RALPH_MAX_ITERATIONS` | `10` | Maximum iterations (`-1` for unlimited) |
| `RALPH_PROFILE` | `-` | Quality profile (`lite`, `plus`, `pro`, `super`, `ultra`) |
| `RALPH_MONITOR_MODEL` | `-` | Monitor model (fallback parser) |
| `RALPH_MONITOR_PROVIDER` | `-` | Monitor provider |
| `RALPH_MAX_RETRIES` | `3` | Max rate-limit retries |
| `RALPH_INITIAL_BACKOFF` | `5` | Initial retry backoff in seconds |
| `RALPH_THROTTLE_DELAY` | `0` | Proactive throttle delay in seconds |
| `RALPH_STATE_BASE` | `${PLUGIN_DATA}/state` or `.ralph` | Session state directory |
| `RALPH_RECIPE_DIR` | `${PLUGIN_ROOT}/recipes` | Recipes directory |
| `MCP_TRANSPORT` | `stdio` | MCP transport (`stdio` or `streamable-http`) |
| `MCP_HTTP_HOST` | `127.0.0.1` | Streamable HTTP bind host |
| `MCP_HTTP_PORT` | `8080` | Streamable HTTP TCP port |
| `MCP_HTTP_ENDPOINT` | `/mcp` | Streamable HTTP endpoint path |

---

## 5. Quality Profiles

Located in `profiles/`:

| Profile | Max Iterations | Worker Model | Reviewer Model | Use Case |
|---------|----------------|--------------|----------------|----------|
| **lite** | 30 | gemma-4-31b-it | meta/muse-glimmer-30b | Fast, cost-effective iterations |
| **plus** | 30 | deepseek-v4-flash-0731 | gemma-4-31b-it | Balanced quality/speed |
| **pro** | 45 | nemotron-3-ultra-550b | gemma-4-31b-it | High-quality code generation |
| **super** | 60 | deepseek-v4-pro-0813 | nemotron-3-ultra-550b | Production-grade output |
| **ultra** | 80 | glm-5.3 | nemotron-3-ultra-550b | Maximum quality, longest runs |

Apply a profile with `--profile <name>` or set `RALPH_PROFILE`.

---

## 6. Prerequisites

- `jq` — JSON processor
  - Linux: `apt-get install jq` / `yum install jq` / `apk add jq`
  - macOS: `brew install jq`
  - Windows: `choco install jq` / `winget install jqlang.jq` / `scoop install jq`
- Bash (Linux/macOS) or PowerShell 5.1+ / `pwsh` 7+ (Windows)
- `socat` or `nc` (Linux/macOS only, when running `streamable-http` service)
- At least one LLM CLI tool installed (`claude`, `openai`, `gemini`, `copilot`, `goose`)

---

## 7. Supported Providers

| Provider | CLI Command | Notes |
|----------|-------------|-------|
| Anthropic | `claude --model <model> --print` | Requires Anthropic API key |
| OpenAI | `openai chat --model <model> --no-stream` | Requires OpenAI API key |
| Google | `gemini --model <model> --format=text` | Requires Google API key |
| GitHub Copilot | `copilot -p --allow-all-tools --model <model>` | Requires `gh auth login` + Copilot subscription |
| Goose | `goose run --recipe <file> --session <id>` | Uses Goose recipes |
| NVIDIA | `nvidia-nim` or compatible | Requires NVIDIA API key |

---

## 8. CLI & In-Session Usage

```bash
# Run automated Worker/Reviewer loop via CLI (Linux/macOS)
./bin/script-runner.sh ralph-wiggum-loop "Implement user authentication with JWT tokens" --profile pro

# Start in-session Stop-hook loop (.agents/ralph-loop.local.md)
./bin/script-runner.sh setup-ralph-loop "Implement user authentication with JWT tokens" --max-iterations 20 --completion-promise "DONE"

# Run as MCP server (stdio mode)
./bin/script-runner.sh ralph-wiggum-loop --stdio
```

```powershell
# Run automated Worker/Reviewer loop via CLI (Windows PowerShell)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop "Implement user authentication with JWT tokens" --profile pro

# Start in-session Stop-hook loop (.agents/ralph-loop.local.md)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 setup-ralph-loop "Implement user authentication with JWT tokens" --max-iterations 20 --completion-promise "DONE"

# Run as MCP server (stdio mode)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 ralph-wiggum-loop --stdio
```

---

## 9. State Storage

Multi-model MCP session state is stored in `${RALPH_STATE_BASE}/<sessionId>/` (defaults to `${PLUGIN_DATA}/state/<sessionId>/` or `<workspace>/.ralph/<sessionId>/`), and in-session Stop-hook state is stored in `.agents/ralph-loop.local.md`:

```text
<workspace>/.ralph/my-feature/
+-- config.json          # Worker/reviewer/monitor config
+-- task.json            # Original task
+-- work.json            # Current work submission (ralph_loop_submit_work)
+-- review.json          # Current review (ralph_loop_submit_review)
+-- work-complete.txt    # Worker completion flag
+-- review-result.txt    # SHIP/REVISE decision
+-- review-feedback.txt  # Reviewer feedback
+-- RALPH-BLOCKED.md     # Blocking reason (if any)
+-- history/
    +-- iteration_1/
    |   +-- work.json
    |   +-- review.json
    |   +-- work.out
    |   +-- review.out
    +-- iteration_2/
        +-- ...
```
