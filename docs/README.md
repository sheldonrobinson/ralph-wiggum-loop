# ralph-wiggum-loop

> **Multi-model iterative development agent plugin** — Ralph Loop with cross-model worker/reviewer architecture and SHIP/REVISE decision engine.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Agent Plugin](https://img.shields.io/badge/Agent--Plugins-v1.0.0-blue)](https://agent-plugins.org)
[![GitHub Pages](https://github.com/sheldonrobinson/ralph-wiggum-loop/actions/workflows/pages.yml/badge.svg)](https://sheldonrobinson.github.io/ralph-wiggum-loop)

## Overview

The Ralph Loop implements a two-phase iterative workflow where a **worker** model does the work and a **reviewer** model provides cross-model review, iterating until the reviewer says **"SHIP"**.

This project is a **cross-platform Agent Plugin** that provides both:
- **MCP Server Mode** — 11 tools over stdio for integration with AI agents
- **CLI Mode** — Run the full loop directly from the command line

## Quick Start

### CLI Mode
```bash
./bin/ralph-wiggum-loop.sh "Implement user authentication with JWT tokens"
```

### MCP Server Mode
```bash
# Run without arguments to start the MCP server
./bin/ralph-wiggum-loop.sh
```

### With a Quality Profile
```bash
./bin/ralph-wiggum-loop.sh "Write a REST API" --profile pro
```

## Documentation

- [Full Documentation](./docs/README.md) — API reference, tools, state management
- [Deployment Guide](https://sheldonrobinson.github.io/ralph-wiggum-loop/deploy) — Install and configure

## Repository

- **Source:** <https://github.com/sheldonrobinson/ralph-wiggum-loop>
- **Agent Plugin Spec:** <https://agent-plugins.org>
- **MCP Spec:** <https://modelcontextprotocol.io>

## License

MIT
