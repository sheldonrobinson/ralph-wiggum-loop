#!/usr/bin/env sh
# Ralph Wiggum Loop - In-Session Setup Script (POSIX sh compliant)
# Creates state file (.agents/ralph-loop.local.md) for in-session Stop hook loops

set -eu

PROMPT=""
MAX_ITERATIONS=0
COMPLETION_PROMISE="DONE"
STATE_FILE="${RALPH_LOCAL_STATE_FILE:-.agents/ralph-loop.local.md}"

is_non_neg_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

while [ $# -gt 0 ]; do
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
      if [ $# -lt 2 ] || [ -z "${2:-}" ] || ! is_non_neg_int "$2"; then
        echo "Error: --max-iterations requires a non-negative integer" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "Error: --completion-promise requires a text argument" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    *)
      if [ -z "$PROMPT" ]; then
        PROMPT="$1"
      else
        PROMPT="$PROMPT $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$PROMPT" ]; then
  echo "Error: No prompt provided. Usage: setup-ralph-loop.sh <PROMPT> [--max-iterations N] [--completion-promise TEXT]" >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"

if [ -n "$COMPLETION_PROMISE" ] && [ "$COMPLETION_PROMISE" != "null" ]; then
  ESCAPED_PROMISE=$(printf '%s' "$COMPLETION_PROMISE" | sed 's/"/\\"/g')
  COMPLETION_PROMISE_YAML="\"${ESCAPED_PROMISE}\""
else
  COMPLETION_PROMISE_YAML="null"
fi

if [ "$MAX_ITERATIONS" -gt 0 ]; then
  MAX_ITER_DISPLAY="$MAX_ITERATIONS"
else
  MAX_ITER_DISPLAY="unlimited"
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
- Max iterations: $MAX_ITER_DISPLAY
- Completion promise: <promise>$COMPLETION_PROMISE</promise>

Work on the task. When you attempt to exit, the Stop hook will re-feed the prompt until <promise>$COMPLETION_PROMISE</promise> is genuinely true or max iterations are reached.
EOF
