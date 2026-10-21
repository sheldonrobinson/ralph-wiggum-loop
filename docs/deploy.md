---
layout: page
title: Deployment Guide
permalink: /deploy/
---

# Deployment Guide

## Install from Source

```bash
git clone https://github.com/sheldonrobinson/ralph-wiggum-loop
cd ralph-wiggum-loop
chmod +x bin/ralph-wiggum-loop.sh bin/script-runner.sh
```

### Install Agent Skill to `.agents/skills/`

Per the [Agent Skills Specification](https://agentskills.io/specification), copy the skill directory to `.agents/skills/` (project-level `<project>/.agents/skills/ralph-wiggum-loop` or user-level `~/.agents/skills/ralph-wiggum-loop`):

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

## Configure as MCP Server

The plugin includes `mcp.json` conforming to the Agent Plugins v1.0.0 specification with OS-specific `stdio` servers and a `streamable-http` server:

- **Linux / macOS (Bash `stdio`):** `ralph-wiggum-loop`
- **Windows (PowerShell 7+ `stdio`):** `ralph-wiggum-loop-pwsh`
- **Windows (Windows PowerShell 5.1 `stdio`):** `ralph-wiggum-loop-powershell`
- **Streamable HTTP (`http://127.0.0.1:8080/mcp`):** `ralph-wiggum-loop-http`

### Linux / macOS (`stdio`)
```json
{
  "mcpServers": {
    "ralph-wiggum-loop": {
      "type": "stdio",
      "command": "./bin/ralph-wiggum-loop.sh",
      "args": ["--stdio"],
      "cwd": "${PLUGIN_ROOT}"
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
      "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/ralph-wiggum-loop.ps1", "--stdio"],
      "cwd": "${PLUGIN_ROOT}"
    }
  }
}
```
*(Use `"command": "powershell.exe"` on Windows PowerShell 5.1.)*

### Streamable HTTP Service (`streamable-http`)

To use the `ralph-wiggum-loop-http` entry (`http://127.0.0.1:8080/mcp`), start the HTTP service for your OS:

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

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPH_WORKER_MODEL` | — | Worker LLM model name (e.g., `claude-3-5-sonnet`, `gpt-4o`) |
| `RALPH_WORKER_PROVIDER` | — | Worker provider (`anthropic`, `openai`, `google`, `copilot`, `goose`, `nvidia`) |
| `RALPH_WORKER_AGENT` | `goose` | Worker agent |
| `RALPH_REVIEWER_MODEL` | — | Reviewer LLM model name |
| `RALPH_REVIEWER_PROVIDER` | — | Reviewer provider |
| `RALPH_REVIEWER_AGENT` | `goose` | Reviewer agent |
| `RALPH_MAX_ITERATIONS` | `10` | Maximum iterations (`-1` for unlimited) |
| `RALPH_PROFILE` | — | Quality profile (`lite`, `plus`, `pro`, `super`, `ultra`) |
| `RALPH_MONITOR_MODEL` | — | Monitor model (fallback parser) |
| `RALPH_MONITOR_PROVIDER` | — | Monitor provider |
| `RALPH_MAX_RETRIES` | `3` | Max rate-limit retries |
| `RALPH_INITIAL_BACKOFF` | `5` | Initial retry backoff in seconds |
| `RALPH_THROTTLE_DELAY` | `0` | Proactive throttle delay in seconds |
| `RALPH_RECIPE_DIR` | `/usr/local/share/ralph-wiggum-loop/recipes` | Recipes directory |

## Quality Profiles

Located in `profiles/`:

| Profile | Max Iterations | Worker Model | Reviewer Model | Use Case |
|---------|----------------|--------------|----------------|----------|
| **lite** | 30 | gemma-4-31b-it | meta/muse-glimmer-30b | Fast, cost-effective iterations |
| **plus** | 30 | deepseek-v4-flash-0731 | gemma-4-31b-it | Balanced quality/speed |
| **pro** | 45 | nemotron-3-ultra-550b | gemma-4-31b-it | High-quality code generation |
| **super** | 60 | deepseek-v4-pro-0813 | nemotron-3-ultra-550b | Production-grade output |
| **ultra** | 80 | glm-5.3 | nemotron-3-ultra-550b | Maximum quality, longest runs |

Apply a profile with `--profile <name>` or set `RALPH_PROFILE`.

## Prerequisites

- `jq` — JSON processor
  - Linux: `apt-get install jq` / `yum install jq` / `apk add jq`
  - macOS: `brew install jq`
  - Windows: `choco install jq` / `winget install jqlang.jq` / `scoop install jq`
- Bash (Linux/macOS) or PowerShell 5.1+ (Windows)
- At least one LLM CLI tool installed (`claude`, `openai`, `gemini`, `copilot`, `goose`)
- API keys configured for your chosen providers

## Supported Providers

| Provider | CLI Command | Notes |
|----------|-------------|-------|
| Anthropic | `claude --model <model> --print` | Requires Anthropic API key |
| OpenAI | `openai chat --model <model> --no-stream` | Requires OpenAI API key |
| Google | `gemini --model <model> --format=text` | Requires Google API key |
| GitHub Copilot | `copilot -p --allow-all-tools --model <model>` | Requires `gh auth login` + Copilot subscription |
| Goose | `goose run --recipe <file> --session <id>` | Uses Goose recipes |
| NVIDIA | `nvidia-nim` or compatible | Requires NVIDIA API key |

## CLI Usage

```bash
# Run with a task
./bin/ralph-wiggum-loop.sh "Implement user authentication with JWT tokens"

# Run with profile
./bin/ralph-wiggum-loop.sh "Write a REST API" --profile pro

# Run as MCP server (no args = stdio mode)
./bin/ralph-wiggum-loop.sh
```

## State Storage

All session state is stored in `<workspace>/.ralph/<sessionId>/`:

```
<workspace>/.ralph/my-feature/
├── config.json        # Worker/reviewer/monitor config
├── task.json          # Original task
├── work.json          # Current work submission
├── review.json        # Current review
├── work-complete.txt  # Worker completion flag
├── review-result.txt  # SHIP/REVISE decision
├── review-feedback.txt # Reviewer feedback
├── RALPH-BLOCKED.md   # Blocking reason (if any)
└── history/
    ├── iteration_1/
    │   ├── work.json
    │   ├── review.json
    │   ├── work.out
    │   └── review.out
    └── iteration_2/
        └── ...
```
