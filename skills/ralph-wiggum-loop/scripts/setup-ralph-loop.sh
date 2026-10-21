#!/usr/bin/env bash
# Ralph Wiggum Loop - In-Session Setup Script
# Creates state file (.agents/ralph-loop.local.md) for in-session Stop hook loops

set -euo pipefail

PROMPT_PARTS=()
MAX_ITERATIONS=0
COMPLETION_PROMISE="DONE"
STATE_FILE="${RALPH_LOCAL_STATE_FILE:-.agents/ralph-loop.local.md}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat << 'HELP_EOF'
Ralph Wiggum Loop - Interactive self-referential development loop

USAGE:
  scripts/setup-ralph-loop.sh [PROMPT...] [OPTIONS]

ARGUMENTS:
  PROMPT...    Initial task or specification prompt to start the loop

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: 0 = unlimited)
  --completion-promise '<text>'  Promise phrase inside <promise>...</promise> (default: DONE)
  -h, --help                     Show this help message
HELP_EOF
      exit 0
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations requires a non-negative integer" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires a text argument" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    *)
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${PROMPT_PARTS[*]:-}"

if [[ -z "$PROMPT" ]]; then
  echo "Error: No prompt provided. Usage: setup-ralph-loop.sh <PROMPT> [--max-iterations N] [--completion-promise TEXT]" >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"

if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  COMPLETION_PROMISE_YAML="\"${COMPLETION_PROMISE//\"/\\\"}\""
else
  COMPLETION_PROMISE_YAML="null"
fi

cat > "$STATE_FILE" <<EOF
---
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

cat <<EOF
Ralph Wiggum loop activated in this session!
- State file: $STATE_FILE
- Iteration: 1
- Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
- Completion promise: <promise>$COMPLETION_PROMISE</promise>

Work on the task. When you attempt to exit, the Stop hook will re-feed the prompt until <promise>$COMPLETION_PROMISE</promise> is genuinely true or max iterations are reached.
EOF
