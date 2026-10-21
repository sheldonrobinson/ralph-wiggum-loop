#!/usr/bin/env bash
# Ralph Wiggum Loop Stop Hook
# Prevents session exit when a Ralph loop is active and completion criteria are not yet met.
# Supports both:
#   1. In-session state file (.agents/ralph-loop.local.md or legacy .claude/ralph-loop.local.md) with <promise>...</promise>
#   2. Multi-model MCP session state (.ralph/<session>/state.json or ${PLUGIN_DATA}/state/<session>/state.json)

set -euo pipefail

HOOK_INPUT="$(cat || true)"

RALPH_STATE_FILE="${RALPH_LOCAL_STATE_FILE:-.agents/ralph-loop.local.md}"
if [[ ! -f "$RALPH_STATE_FILE" && -f ".claude/ralph-loop.local.md" ]]; then
  RALPH_STATE_FILE=".claude/ralph-loop.local.md"
fi
RALPH_MCP_STATE_BASE="${RALPH_STATE_BASE:-${PLUGIN_DATA:+${PLUGIN_DATA}/state}}"
RALPH_MCP_STATE_BASE="${RALPH_MCP_STATE_BASE:-.ralph}"

extract_last_assistant_text() {
  local hook_json="${1:-}"
  if [[ -z "$hook_json" ]]; then
    return 0
  fi
  local transcript_path
  transcript_path=$(printf '%s' "$hook_json" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    return 0
  fi
  local last_line
  last_line=$(grep '"role":"assistant"' "$transcript_path" 2>/dev/null | tail -1 || true)
  if [[ -z "$last_line" ]]; then
    return 0
  fi
  printf '%s' "$last_line" | jq -r '
    .message.content
    | if type == "array" then
        map(select(.type == "text") | .text) | join("\n")
      elif type == "string" then
        .
      else
        ""
      end
  ' 2>/dev/null || true
}

# 1. Check in-session markdown state file (.claude/ralph-loop.local.md)
if [[ -f "$RALPH_STATE_FILE" ]]; then
  FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
  ITERATION=$(printf '%s\n' "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//' | tr -d '\r')
  MAX_ITERATIONS=$(printf '%s\n' "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//' | tr -d '\r')
  COMPLETION_PROMISE=$(printf '%s\n' "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/' | tr -d '\r')

  if [[ ! "$ITERATION" =~ ^[0-9]+$ ]] || [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    echo "Ralph loop: corrupted state file ($RALPH_STATE_FILE); stopping loop." >&2
    rm -f "$RALPH_STATE_FILE"
    exit 0
  fi

  if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    rm -f "$RALPH_STATE_FILE"
    exit 0
  fi

  LAST_OUTPUT="$(extract_last_assistant_text "$HOOK_INPUT")"

  if [[ -n "$COMPLETION_PROMISE" && "$COMPLETION_PROMISE" != "null" && -n "$LAST_OUTPUT" ]]; then
    if [[ "$LAST_OUTPUT" == *"<promise>${COMPLETION_PROMISE}</promise>"* ]]; then
      rm -f "$RALPH_STATE_FILE"
      exit 0
    fi
  fi

  NEXT_ITERATION=$((ITERATION + 1))
  PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE" | sed '/./,$!d')
  if [[ -z "$PROMPT_TEXT" ]]; then
    rm -f "$RALPH_STATE_FILE"
    exit 0
  fi

  TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
  sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$RALPH_STATE_FILE"

  if [[ -n "$COMPLETION_PROMISE" && "$COMPLETION_PROMISE" != "null" ]]; then
    SYSTEM_MSG="Ralph iteration $NEXT_ITERATION | To complete: output <promise>$COMPLETION_PROMISE</promise> (ONLY when all acceptance criteria and tests pass)"
  else
    SYSTEM_MSG="Ralph iteration $NEXT_ITERATION | No completion promise set"
  fi

  jq -n \
    --arg prompt "$PROMPT_TEXT" \
    --arg msg "$SYSTEM_MSG" \
    '{
      "decision": "block",
      "reason": $prompt,
      "systemMessage": $msg
    }'
  exit 0
fi

# 2. Check active MCP Worker/Reviewer loop state if present
if [[ -d "$RALPH_MCP_STATE_BASE" ]]; then
  for state_json in "$RALPH_MCP_STATE_BASE"/*/state.json; do
    [[ -f "$state_json" ]] || continue
    STATUS=$(jq -r '.status // "idle"' "$state_json" 2>/dev/null || echo "idle")
    PHASE=$(jq -r '.current_phase // "idle"' "$state_json" 2>/dev/null || echo "idle")
    ITER=$(jq -r '.iteration // 0' "$state_json" 2>/dev/null || echo "0")
    MAX_ITER=$(jq -r '.max_iterations // 5' "$state_json" 2>/dev/null || echo "5")
    SESSION_ID=$(jq -r '.session_id // "default"' "$state_json" 2>/dev/null || echo "default")

    if [[ "$STATUS" == "in_progress" || "$STATUS" == "revising" ]]; then
      if [[ "$ITER" -lt "$MAX_ITER" ]]; then
        TASK_DESC=$(jq -r '.task_description // ""' "$state_json" 2>/dev/null || echo "")
        FEEDBACK=$(jq -r '.review_feedback // ""' "$state_json" 2>/dev/null || echo "")
        REASON="Ralph Wiggum MCP session '$SESSION_ID' is still active (phase: $PHASE, status: $STATUS, iteration: $ITER/$MAX_ITER). Task: $TASK_DESC"
        if [[ -n "$FEEDBACK" ]]; then
          REASON="${REASON} | Latest Reviewer Feedback: ${FEEDBACK}"
        fi
        SYSTEM_MSG="Ralph MCP Loop ($SESSION_ID) iteration $ITER/$MAX_ITER [$PHASE] - Complete review with SHIP to finish."
        jq -n \
          --arg prompt "$REASON" \
          --arg msg "$SYSTEM_MSG" \
          '{
            "decision": "block",
            "reason": $prompt,
            "systemMessage": $msg
          }'
        exit 0
      fi
    fi
  done
fi

exit 0
