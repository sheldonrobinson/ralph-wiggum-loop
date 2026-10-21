#!/usr/bin/env bash
# Ralph Wiggum Loop — Streamable HTTP Service Manager (Linux / macOS - Bash)
# Starts, stops, or checks the status of the Streamable HTTP MCP server.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve_plugin_root() {
  if [[ -n "${PLUGIN_ROOT:-}" && -f "${PLUGIN_ROOT}/bin/ralph-wiggum-loop.sh" ]]; then
    printf '%s\n' "${PLUGIN_ROOT}"
    return 0
  fi
  local cand
  for cand in \
    "$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || true)" \
    "$(cd "${SCRIPT_DIR}/../../../.." 2>/dev/null && pwd || true)" \
    "$(pwd)"
  do
    if [[ -n "${cand}" && -f "${cand}/bin/ralph-wiggum-loop.sh" ]]; then
      printf '%s\n' "${cand}"
      return 0
    fi
  done
  cd "${SCRIPT_DIR}/../../.." && pwd
}
PLUGIN_ROOT="$(resolve_plugin_root)"
SERVER_SCRIPT="${PLUGIN_ROOT}/bin/ralph-wiggum-loop.sh"

ACTION="start"
HOST="${MCP_HTTP_HOST:-127.0.0.1}"
PORT="${MCP_HTTP_PORT:-8080}"
ENDPOINT="${MCP_HTTP_ENDPOINT:-/mcp}"
STATE_DIR="${PLUGIN_DATA:-${PLUGIN_ROOT}/.ralph}"
PID_FILE="${STATE_DIR}/ralph-http-server.pid"
LOG_FILE="${STATE_DIR}/ralph-http-server.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    start|stop|status|foreground)
      ACTION="$1"
      shift
      ;;
    --host)
      HOST="${2:-127.0.0.1}"
      shift 2
      ;;
    --port)
      PORT="${2:-8080}"
      shift 2
      ;;
    --endpoint)
      ENDPOINT="${2:-/mcp}"
      shift 2
      ;;
    -h|--help)
      cat << 'EOF'
Ralph Wiggum Loop — Streamable HTTP Service Manager (Linux/macOS)

USAGE:
  ./skills/ralph-wiggum-loop/scripts/start-http-server.sh [start|stop|status|foreground] [OPTIONS]

COMMANDS:
  start        Start the Streamable HTTP MCP server in the background (default)
  foreground   Run the Streamable HTTP MCP server in the foreground
  status       Check if the server is running and responsive
  stop         Stop the background server cleanly

OPTIONS:
  --host <ip>        Bind address (default: 127.0.0.1)
  --port <port>      TCP port (default: 8080)
  --endpoint <path>  MCP HTTP endpoint path (default: /mcp)
  -h, --help         Show this help message
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "${STATE_DIR}"

check_pid_running() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      echo "${pid}"
      return 0
    fi
  fi
  return 1
}

case "${ACTION}" in
  foreground)
    export MCP_TRANSPORT="streamable-http"
    export MCP_HTTP_HOST="${HOST}"
    export MCP_HTTP_PORT="${PORT}"
    export MCP_HTTP_ENDPOINT="${ENDPOINT}"
    export MCP_HTTP_LISTEN="true"
    echo "Starting Ralph Wiggum Loop Streamable HTTP server (foreground) at http://${HOST}:${PORT}${ENDPOINT} ..."
    exec "${SERVER_SCRIPT}" --streamable-http --host "${HOST}" --port "${PORT}" --listen
    ;;

  start)
    if running_pid="$(check_pid_running)"; then
      echo "Streamable HTTP server is already running (PID: ${running_pid}) at http://${HOST}:${PORT}${ENDPOINT}"
      exit 0
    fi

    if ! command -v socat >/dev/null 2>&1 && ! command -v nc >/dev/null 2>&1; then
      echo "Error: Either 'socat' or 'nc' (netcat) is required on Linux/macOS to bind TCP port ${PORT}." >&2
      echo "Install with: brew install socat (macOS) or sudo apt-get install -y socat (Linux)" >&2
      exit 1
    fi

    export MCP_TRANSPORT="streamable-http"
    export MCP_HTTP_HOST="${HOST}"
    export MCP_HTTP_PORT="${PORT}"
    export MCP_HTTP_ENDPOINT="${ENDPOINT}"
    export MCP_HTTP_LISTEN="true"

    nohup "${SERVER_SCRIPT}" --streamable-http --host "${HOST}" --port "${PORT}" --listen \
      </dev/null >>"${LOG_FILE}" 2>&1 &
    new_pid=$!
    echo "${new_pid}" > "${PID_FILE}"

    echo "Started Ralph Wiggum Loop Streamable HTTP server (PID: ${new_pid})"
    echo "  Endpoint: http://${HOST}:${PORT}${ENDPOINT}"
    echo "  Log file: ${LOG_FILE}"
    echo "  PID file: ${PID_FILE}"
    ;;

  status)
    if running_pid="$(check_pid_running)"; then
      echo "RUNNING (PID: ${running_pid}) — http://${HOST}:${PORT}${ENDPOINT}"
      exit 0
    else
      echo "STOPPED"
      exit 1
    fi
    ;;

  stop)
    if running_pid="$(check_pid_running)"; then
      kill "${running_pid}" 2>/dev/null || true
      rm -f "${PID_FILE}"
      echo "Stopped Streamable HTTP server (PID: ${running_pid})"
    else
      rm -f "${PID_FILE}"
      echo "Streamable HTTP server is not running."
    fi
    ;;
esac
