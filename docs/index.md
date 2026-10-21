# ralph-wiggum-loop

> Multi-model iterative development agent plugin — Ralph Loop with cross-model worker/reviewer architecture and SHIP/REVISE decision engine.

[Read the full documentation →](./README.md)

## What is the Ralph Loop?

A two-phase iterative workflow where a **worker** model does the work and a **reviewer** model provides cross-model review, iterating until the reviewer says **"SHIP"**.

```
┌─────────┐      WORK PHASE      ┌─────────┐
│  TASK   │ ──────────────────▶  │ WORKER  │
│         │   fresh context      │(Model A)│
└─────────┘                      └────┬────┘
                                       │
                                       ▼
                          ┌───────────────────┐
                          │ Submit Work +     │
                          │ Summary           │
                          └────────┬──────────┘
                                   │
                                   ▼
┌─────────┐      REVIEW PHASE    ┌─────────┐
│REVIEWER │ ◀─────────────────── │  WORK   │
│(Model B)│   cross-model review │ OUTPUT  │
└────┬────┘                      └─────────┘
     │
     ▼
┌─────────┐
│DECISION │──────▶ SHIP ✓
│         │──────▶ REVISE → Next Iteration
└─────────┘
```

## Features

- **Cross-platform Native**: Bash (Linux/macOS) and PowerShell (Windows) — no Node.js runtime required
- **Dual Mode**: MCP Server (stdio) and CLI mode
- **11 MCP Tools**: Complete workflow control including `ralph_loop_run` for full automation
- **Session-based**: Multiple concurrent sessions with file-based state persistence
- **Cross-Model Review**: Configurable worker/reviewer models from different providers
- **Monitoring Agent**: Automatic fallback parsing when regex extraction fails
- **Multiple LLM Providers**: Anthropic, OpenAI, Google (Gemini), GitHub Copilot, Goose, NVIDIA
- **5 Quality Profiles**: lite, plus, pro, super, ultra — pre-configured model combinations
- **Rate-Limit Aware**: Configurable retries, backoff, and throttling

## Quick Start

```bash
# Clone and install
git clone https://github.com/sheldonrobinson/ralph-wiggum-loop
cd ralph-wiggum-loop
chmod +x bin/ralph-wiggum-loop.sh

# Run a task
./bin/ralph-wiggum-loop.sh "Implement user authentication with JWT tokens" --profile pro

# Or run as MCP server (no args)
./bin/ralph-wiggum-loop.sh
```

## Documentation

- [Full README](./README.md) — Complete API reference and usage guide
- [Deployment Guide](/deploy) — Install and configure as MCP server

## Repository

- **Source:** [github.com/sheldonrobinson/ralph-wiggum-loop](https://github.com/sheldonrobinson/ralph-wiggum-loop)
- **Agent Plugin Spec:** [agent-plugins.org](https://agent-plugins.org)
- **MCP Spec:** [modelcontextprotocol.io](https://modelcontextprotocol.io)

## License

MIT
