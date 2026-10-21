#!/usr/bin/env bash
# mcp-sdk.sh - Generic Shebang MCP SDK (Bash)
# Implementation of the Model Context Protocol (MCP) specification (latest: 2025-03-26 / 2024-11-05)
# Supports both stdio and streamable-http transports.
#
# This SDK is strictly generic and provides core MCP protocol functions usable by any
# shell-based MCP server. It contains NO application-specific logic.
#
# ============================================================================
# REQUIRED features (MUST implement per MCP specification):
#   - JSON-RPC 2.0 envelope (jsonrpc: "2.0") on every message
#   - initialize request       -> capabilities, serverInfo, protocolVersion
#   - notifications/initialized (and initialized) -> handled silently (no response)
#   - ping request             -> empty object {} response
#   - tools/list               -> list of available tools
#   - tools/call               -> invoke a named tool with arguments
#   - Standard JSON-RPC 2.0 error codes (-32700, -32600, -32601, -32602, -32603)
#   - Transports: stdio and streamable-http
#   - On-exit cleanup handler (trap EXIT / INT / TERM / HUP)
#
# OPTIONAL features (explicitly NOT implemented):
#   - Authorization, Elicitation, Roots, Sampling, Completions, Logging
#
# DEPRECATED features (explicitly NOT implemented):
#   - Legacy HTTP+SSE transport (2024-11-05 separate SSE endpoint)
# ============================================================================

set -euo pipefail

# --- Protocol constants -----------------------------------------------------
MCP_PROTOCOL_VERSION="${MCP_PROTOCOL_VERSION:-2025-03-26}"
MCP_SUPPORTED_VERSIONS=("2025-03-26" "2024-11-05")
MCP_SERVER_NAME="${MCP_SERVER_NAME:-shebang-mcp-sdk}"
MCP_SERVER_VERSION="${MCP_SERVER_VERSION:-1.0.0}"

# --- Transport and connection state -----------------------------------------
MCP_TRANSPORT="${MCP_TRANSPORT:-stdio}"
MCP_HTTP_HOST="${MCP_HTTP_HOST:-127.0.0.1}"
MCP_HTTP_PORT="${MCP_HTTP_PORT:-8080}"
MCP_HTTP_ENDPOINT="${MCP_HTTP_ENDPOINT:-/mcp}"
MCP_SESSION_ID=""
MCP_INITIALIZED="false"
MCP_HTTP_SERVER_PID=""
MCP_CLEANUP_DONE="false"
declare -a MCP_CLEANUP_HOOKS=()
declare -a MCP_TEMP_FILES=()

# --- On-Exit & Connection Cleanup Handler -----------------------------------
# Register a custom cleanup callback function name to run on exit
mcp_register_cleanup() {
    local hook="${1:-}"
    if [[ -n "${hook}" ]]; then
        MCP_CLEANUP_HOOKS+=("${hook}")
    fi
}

# Close active MCP transport connections and release resources
mcp_close_connection() {
    # Stop background HTTP listener if running
    if [[ -n "${MCP_HTTP_SERVER_PID:-}" ]]; then
        if kill -0 "${MCP_HTTP_SERVER_PID}" 2>/dev/null; then
            kill "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
            wait "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
        fi
        MCP_HTTP_SERVER_PID=""
    fi

    # Remove any temporary files/FIFOs created by the transport
    if [[ ${#MCP_TEMP_FILES[@]} -gt 0 ]]; then
        local f
        for f in "${MCP_TEMP_FILES[@]}"; do
            [[ -n "${f}" && -e "${f}" ]] && rm -rf "${f}" 2>/dev/null || true
        done
        MCP_TEMP_FILES=()
    fi

    MCP_INITIALIZED="false"
    MCP_SESSION_ID=""
}

# Trap handler invoked on EXIT, INT, TERM, HUP
mcp_on_exit() {
    local exit_code=$?
    trap - EXIT INT TERM HUP
    if [[ "${MCP_CLEANUP_DONE}" == "true" ]]; then
        return "${exit_code}"
    fi
    MCP_CLEANUP_DONE="true"

    # Run registered consumer cleanup hooks if any
    if [[ ${#MCP_CLEANUP_HOOKS[@]} -gt 0 ]]; then
        local hook
        for hook in "${MCP_CLEANUP_HOOKS[@]}"; do
            if declare -F "${hook}" >/dev/null 2>&1; then
                "${hook}" || true
            fi
        done
    fi

    # Close connections and clean up transport resources
    mcp_close_connection || true

    return "${exit_code}"
}

mcp_on_signal() {
    local sig="${1:-TERM}"
    local code="${2:-143}"
    mcp_on_exit || true
    exit "${code}"
}

trap mcp_on_exit EXIT
trap 'mcp_on_signal INT 130' INT
trap 'mcp_on_signal TERM 143' TERM
trap 'mcp_on_signal HUP 129' HUP

# --- JSON-RPC 2.0 helpers ---------------------------------------------------
json_escape() {
    printf '%s' "${1:-}" | jq -Rs .
}

# JSON-RPC 2.0 response constructor
# Usage: json_response <id> <result_json> [error_json]
#   id         : request id (number/string) or "null"/"" for null id
#   result_json: valid JSON string for the result (default "{}")
#   error_json : valid JSON string for the error, or empty for success
json_response() {
    local id="${1:-null}"
    local result=${2:-"{}"}
    local error="${3:-}"

    # Build the id expression for jq (properly handles JSON null, numbers, and strings)
    local id_expr
    if [[ -z "${id}" || "${id}" == "null" ]]; then
        id_expr="null"
    elif [[ "${id}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        id_expr="${id}"
    elif [[ "${id}" =~ ^\".*\"$ ]]; then
        id_expr="${id}"
    else
        id_expr=$(printf '%s' "${id}" | jq -Rs .)
    fi

    local payload
    if [[ -n "${error}" ]]; then
        if printf '%s' "${error}" | jq -e . >/dev/null 2>&1; then
            payload=$(jq -cn \
                --argjson id "${id_expr}" \
                --argjson err "${error}" \
                '{jsonrpc:"2.0", id:$id, error:$err}')
        else
            payload=$(jq -cn \
                --argjson id "${id_expr}" \
                --arg msg "${error}" \
                '{jsonrpc:"2.0", id:$id, error:{code:-32603, message:$msg}}')
        fi
    else
        local result_json="{}"
        if [[ -n "${result}" ]]; then
            if printf '%s' "${result}" | jq -e . >/dev/null 2>&1; then
                result_json="${result}"
            else
                result_json=$(printf '%s' "${result}" | jq -Rs '{content:[{type:"text",text:.}]}')
            fi
        fi
        payload=$(jq -cn \
            --argjson id "${id_expr}" \
            --argjson res "${result_json}" \
            '{jsonrpc:"2.0", id:$id, result:$res}')
    fi
    printf '%s\n' "${payload}"
}

# JSON-RPC 2.0 error object constructor
# Usage: mcp_error <code> <message> [data_json]
mcp_error() {
    local code="${1:--32603}"
    local message="${2:-Internal error}"
    local data="${3:-null}"
    if [[ -z "${data}" || "${data}" == "null" ]]; then
        jq -cn --argjson code "${code}" --arg message "${message}" \
            '{code:$code, message:$message}'
    else
        if ! printf '%s' "${data}" | jq -e . >/dev/null 2>&1; then
            data=$(printf '%s' "${data}" | jq -Rs .)
        fi
        jq -cn --argjson code "${code}" --arg message "${message}" --argjson data "${data}" \
            '{code:$code, message:$message, data:$data}'
    fi
}

# Format a tool result per MCP spec (content array with text item + optional structured/raw fields)
# Usage: mcp_tool_result <text_or_json> [is_error]
mcp_tool_result() {
    local content="${1:-}"
    local is_error="${2:-false}"
    jq -cn --arg text "${content}" --argjson isError "${is_error}" \
        '{content:[{type:"text", text:$text}], isError:$isError}'
}

# Validate and parse incoming JSON-RPC 2.0 message
# Usage: mcp_parse_message <message>
# Prints:
#   VALID=<true|false>
#   IS_NOTIFICATION=<true|false>
#   ID=<id_or_null>
#   METHOD=<method>
#   PARAMS=<params_json>
mcp_parse_message() {
    local message="${1:-}"
    if ! printf '%s' "${message}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf 'VALID=false\nIS_NOTIFICATION=false\nID=null\nMETHOD=\nPARAMS={}\n'
        return 0
    fi

    local jsonrpc has_id id method params is_notification
    jsonrpc=$(printf '%s' "${message}" | jq -r '.jsonrpc // ""' 2>/dev/null || echo "")
    has_id=$(printf '%s' "${message}" | jq -r 'has("id")' 2>/dev/null || echo "false")
    id=$(printf '%s' "${message}" | jq -r 'if .id == null then "null" else (.id | tostring) end' 2>/dev/null || echo "null")
    method=$(printf '%s' "${message}" | jq -r 'if (.method | type) == "string" then .method else "" end' 2>/dev/null || echo "")
    params=$(printf '%s' "${message}" | jq -c '.params // {}' 2>/dev/null || echo "{}")

    if [[ "${has_id}" == "false" ]]; then
        is_notification="true"
    else
        is_notification="false"
    fi

    printf 'VALID=true\nJSONRPC=%s\nIS_NOTIFICATION=%s\nID=%s\nMETHOD=%s\nPARAMS=%s\n' \
        "${jsonrpc}" "${is_notification}" "${id}" "${method}" "${params}"
}

# ============================================================================
# MCP METHOD HANDLERS (generic protocol handlers; overridable by consumers)
# ============================================================================

# Handle MCP initialize request
handle_initialize() {
    local id="${1}"
    local params=${2:-"{}"}

    local client_version negotiated_version
    client_version=$(printf '%s' "${params}" | jq -r '.protocolVersion // ""' 2>/dev/null || echo "")
    negotiated_version="${MCP_PROTOCOL_VERSION}"

    if [[ -n "${client_version}" ]]; then
        local v
        for v in "${MCP_SUPPORTED_VERSIONS[@]}"; do
            if [[ "${v}" == "${client_version}" ]]; then
                negotiated_version="${client_version}"
                break
            fi
        done
    fi

    MCP_INITIALIZED="true"

    local capabilities server_info result
    capabilities=$(jq -cn '{tools:{}}')
    server_info=$(jq -cn --arg name "${MCP_SERVER_NAME}" --arg version "${MCP_SERVER_VERSION}" \
        '{name:$name, version:$version}')
    result=$(jq -cn \
        --arg proto "${negotiated_version}" \
        --argjson caps "${capabilities}" \
        --argjson info "${server_info}" \
        '{protocolVersion:$proto, capabilities:$caps, serverInfo:$info}')
    json_response "${id}" "${result}"
}

# Handle notifications/initialized (and legacy initialized) notification
# Notifications MUST NOT produce a response.
handle_initialized() {
    MCP_INITIALIZED="true"
    return 0
}

# Handle MCP ping request
handle_ping() {
    local id="${1}"
    json_response "${id}" "{}"
}

# Default generic tools/list handler (consumers can override handle_tools_list or handle_list_tools)
handle_tools_list() {
    local id="${1}"
    local params=${2:-"{}"}

    if declare -F handle_list_tools >/dev/null 2>&1; then
        handle_list_tools "${id}" "${params}"
        return 0
    fi

    local result
    result=$(jq -cn '{tools:[]}')
    json_response "${id}" "${result}"
}

# Default generic tools/call handler (consumers can override handle_tools_call)
handle_tools_call() {
    local id="${1}"
    local params=${2:-"{}"}

    local name
    name=$(printf '%s' "${params}" | jq -r '.name // ""' 2>/dev/null || echo "")
    if [[ -z "${name}" ]]; then
        local err
        err=$(mcp_error -32602 "Invalid params: missing tool name")
        json_response "${id}" "" "${err}"
        return 0
    fi

    local err
    err=$(mcp_error -32601 "Tool not found: ${name}")
    json_response "${id}" "" "${err}"
}

# Generic JSON-RPC 2.0 message dispatcher
# Dispatches a single JSON-RPC message string and prints the response (if any) to stdout.
mcp_dispatch_message() {
    local line="${1:-}"
    [[ -z "${line}" ]] && return 0

    if ! printf '%s' "${line}" | jq -e . >/dev/null 2>&1; then
        local err
        err=$(mcp_error -32700 "Parse error")
        json_response "null" "" "${err}"
        return 0
    fi

    # Support JSON-RPC batch arrays or single objects
    local msg_type
    msg_type=$(printf '%s' "${line}" | jq -r 'type' 2>/dev/null || echo "")
    if [[ "${msg_type}" == "array" ]]; then
        local len
        len=$(printf '%s' "${line}" | jq 'length')
        if [[ "${len}" -eq 0 ]]; then
            local err
            err=$(mcp_error -32600 "Invalid Request: empty batch")
            json_response "null" "" "${err}"
            return 0
        fi
        local responses=()
        local idx item item_resp
        for ((idx = 0; idx < len; idx++)); do
            item=$(printf '%s' "${line}" | jq -c ".[${idx}]")
            item_resp=$(mcp_dispatch_single "${item}")
            if [[ -n "${item_resp}" ]]; then
                responses+=("${item_resp}")
            fi
        done
        if [[ ${#responses[@]} -gt 0 ]]; then
            printf '%s\n' "${responses[@]}" | jq -cs '.'
        fi
        return 0
    elif [[ "${msg_type}" != "object" ]]; then
        local err
        err=$(mcp_error -32600 "Invalid Request")
        json_response "null" "" "${err}"
        return 0
    fi

    mcp_dispatch_single "${line}"
}

mcp_dispatch_single() {
    local message="${1}"
    local parse_result
    parse_result=$(mcp_parse_message "${message}")

    local valid jsonrpc is_notification msg_id msg_method msg_params
    valid=$(printf '%s\n' "${parse_result}" | grep '^VALID=' | cut -d= -f2-)
    jsonrpc=$(printf '%s\n' "${parse_result}" | grep '^JSONRPC=' | cut -d= -f2-)
    is_notification=$(printf '%s\n' "${parse_result}" | grep '^IS_NOTIFICATION=' | cut -d= -f2-)
    msg_id=$(printf '%s\n' "${parse_result}" | grep '^ID=' | cut -d= -f2-)
    msg_method=$(printf '%s\n' "${parse_result}" | grep '^METHOD=' | cut -d= -f2-)
    msg_params=$(printf '%s\n' "${parse_result}" | grep '^PARAMS=' | cut -d= -f2-)

    if [[ "${valid}" != "true" || "${jsonrpc}" != "2.0" ]]; then
        local err
        err=$(mcp_error -32600 "Invalid Request")
        json_response "${msg_id}" "" "${err}"
        return 0
    fi

    # If message is a JSON-RPC response (has result or error and no method), ignore it
    if [[ -z "${msg_method}" ]]; then
        if printf '%s' "${message}" | jq -e 'has("result") or has("error")' >/dev/null 2>&1; then
            return 0
        fi
        local err
        err=$(mcp_error -32600 "Invalid Request: missing method")
        json_response "${msg_id}" "" "${err}"
        return 0
    fi

    case "${msg_method}" in
        initialize)
            handle_initialize "${msg_id}" "${msg_params}"
            ;;
        notifications/initialized|initialized)
            handle_initialized
            ;;
        notifications/*)
            # Ignore other client notifications silently per spec
            return 0
            ;;
        ping)
            handle_ping "${msg_id}"
            ;;
        tools/list)
            handle_tools_list "${msg_id}" "${msg_params}"
            ;;
        tools/call)
            handle_tools_call "${msg_id}" "${msg_params}"
            ;;
        *)
            # Allow custom route hook if consumer defines mcp_custom_method_handler
            if declare -F mcp_custom_method_handler >/dev/null 2>&1; then
                mcp_custom_method_handler "${msg_id}" "${msg_method}" "${msg_params}" "${is_notification}"
                return 0
            fi
            if [[ "${is_notification}" != "true" && "${msg_id}" != "null" && -n "${msg_id}" ]]; then
                local err
                err=$(mcp_error -32601 "Method not found: ${msg_method}")
                json_response "${msg_id}" "" "${err}"
            fi
            ;;
    esac
}

route_mcp_message() {
    mcp_dispatch_message "$@"
}

process_mcp_line() {
    mcp_dispatch_message "$@"
}

# ============================================================================
# TRANSPORT: STDIO
# ============================================================================

# Run MCP server in stdio mode.
# Reads newline-delimited JSON-RPC 2.0 messages from stdin, writes responses to stdout.
mcp_stdio_server() {
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line}" ]] && continue
        mcp_dispatch_message "${line}"
    done
}

# ============================================================================
# TRANSPORT: STREAMABLE-HTTP (MCP 2025-03-26 specification)
# ============================================================================
# Single MCP endpoint supporting POST, GET, DELETE:
#   - POST   : Client sends JSON-RPC message(s).
#              - If request(s): responds 200 OK with application/json (or text/event-stream)
#                and includes Mcp-Session-Id header if session is active.
#              - If notification(s) / response(s) only: responds 202 Accepted with empty body.
#   - GET    : Opens an SSE stream (text/event-stream) or returns 405 Method Not Allowed.
#   - DELETE : Terminates active session (Mcp-Session-Id) and returns 200 OK.

check_curl_available() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    else
        echo "WARNING: curl not found, HTTP client features may be limited" >&2
        return 1
    fi
}

mcp_generate_session_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        printf 'mcp-%s-%s-%s\n' "$(date +%s)" "$$" "${RANDOM}"
    fi
}

extract_jsonrpc_from_post() {
    local http_body="${1:-}"
    if [[ -z "${http_body}" ]]; then
        echo ""
        return 0
    fi
    if printf '%s' "${http_body}" | jq -e . >/dev/null 2>&1; then
        printf '%s' "${http_body}" | jq -c '.'
    else
        echo ""
    fi
}

# Format and send an HTTP response over stdout
# Usage: send_http_response <body_content> [status_code] [content_type] [session_id]
send_http_response() {
    local response_body="${1:-}"
    local status_code="${2:-200}"
    local content_type="${3:-application/json}"
    local session_id="${4:-${MCP_SESSION_ID:-}}"

    local status_text="OK"
    case "${status_code}" in
        200) status_text="OK" ;;
        202) status_text="Accepted" ;;
        204) status_text="No Content" ;;
        400) status_text="Bad Request" ;;
        404) status_text="Not Found" ;;
        405) status_text="Method Not Allowed" ;;
        406) status_text="Not Acceptable" ;;
        500) status_text="Internal Server Error" ;;
        *)   status_text="OK" ;;
    esac

    local content_length
    content_length=$(printf '%s' "${response_body}" | wc -c | tr -d ' ')

    printf 'HTTP/1.1 %s %s\r\n' "${status_code}" "${status_text}"
    if [[ -n "${content_type}" && "${content_length}" -gt 0 ]]; then
        printf 'Content-Type: %s\r\n' "${content_type}"
    fi
    if [[ -n "${session_id}" ]]; then
        printf 'Mcp-Session-Id: %s\r\n' "${session_id}"
    fi
    printf 'Cache-Control: no-cache\r\n'
    printf 'Connection: close\r\n'
    printf 'Content-Length: %d\r\n' "${content_length}"
    printf '\r\n'
    if [[ "${content_length}" -gt 0 ]]; then
        printf '%s' "${response_body}"
    fi
}

# Format a JSON-RPC payload as an SSE (text/event-stream) HTTP response
send_http_sse_response() {
    local response_json="${1:-}"
    local status_code="${2:-200}"
    local session_id="${3:-${MCP_SESSION_ID:-}}"
    local sse_body
    sse_body=$(printf 'event: message\ndata: %s\n\n' "${response_json}")
    send_http_response "${sse_body}" "${status_code}" "text/event-stream" "${session_id}"
}

# Handle HTTP POST request for Streamable HTTP MCP transport
# Usage: handle_http_post <request_body> [accept_header] [session_id_header]
handle_http_post() {
    local request_body="${1:-}"
    local accept_header="${2:-application/json, text/event-stream}"
    local req_session_id="${3:-}"

    if ! printf '%s' "${request_body}" | jq -e . >/dev/null 2>&1; then
        local err_resp
        err_resp=$(json_response "null" "" "$(mcp_error -32700 "Parse error")")
        send_http_response "${err_resp}" 400 "application/json"
        return 0
    fi

    local json_message
    json_message=$(extract_jsonrpc_from_post "${request_body}")
    if [[ -z "${json_message}" ]]; then
        local err_resp
        err_resp=$(json_response "null" "" "$(mcp_error -32600 "Invalid JSON-RPC message")")
        send_http_response "${err_resp}" 400 "application/json"
        return 0
    fi

    # Validate session ID if server already assigned one and this is not initialize
    local method
    method=$(printf '%s' "${json_message}" | jq -r 'if type=="object" then (.method // "") else "" end' 2>/dev/null || echo "")
    if [[ "${method}" == "initialize" && -z "${MCP_SESSION_ID}" ]]; then
        MCP_SESSION_ID=$(mcp_generate_session_id)
    elif [[ -n "${MCP_SESSION_ID}" && -n "${req_session_id}" && "${req_session_id}" != "${MCP_SESSION_ID}" ]]; then
        local err_resp
        err_resp=$(json_response "null" "" "$(mcp_error -32600 "Invalid or expired Mcp-Session-Id")")
        send_http_response "${err_resp}" 404 "application/json"
        return 0
    fi

    local response_payload
    response_payload=$(mcp_dispatch_message "${json_message}")

    # Notification or response-only payload -> 202 Accepted with no body per Streamable HTTP spec
    if [[ -z "${response_payload}" ]]; then
        send_http_response "" 202 "" "${MCP_SESSION_ID}"
        return 0
    fi

    # If client explicitly prefers SSE stream and not application/json
    if [[ "${accept_header}" == *"text/event-stream"* && "${accept_header}" != *"application/json"* ]]; then
        send_http_sse_response "${response_payload}" 200 "${MCP_SESSION_ID}"
    else
        send_http_response "${response_payload}" 200 "application/json" "${MCP_SESSION_ID}"
    fi
}

# Handle HTTP GET request on MCP endpoint (SSE stream or 405)
handle_http_get() {
    local accept_header="${1:-}"
    if [[ "${accept_header}" == *"text/event-stream"* ]]; then
        send_http_response ": streamable-http sse stream open"$'\n\n' 200 "text/event-stream" "${MCP_SESSION_ID}"
    else
        send_http_response "" 405 "text/plain" "${MCP_SESSION_ID}"
    fi
}

# Handle HTTP DELETE request on MCP endpoint (session termination)
handle_http_delete() {
    local req_session_id="${1:-}"
    if [[ -n "${MCP_SESSION_ID}" && -n "${req_session_id}" && "${req_session_id}" != "${MCP_SESSION_ID}" ]]; then
        send_http_response "" 404 "text/plain"
        return 0
    fi
    MCP_SESSION_ID=""
    MCP_INITIALIZED="false"
    send_http_response "" 200 "text/plain"
}

# Parse a raw HTTP request from stdin and dispatch to POST/GET/DELETE handlers
handle_http_request_stream() {
    local request_line=""
    if ! IFS= read -r request_line; then
        return 1
    fi
    request_line="${request_line%$'\r'}"
    [[ -z "${request_line}" ]] && return 1

    local http_method http_path http_version
    read -r http_method http_path http_version <<< "${request_line}"

    local content_length=0
    local accept_header="application/json, text/event-stream"
    local session_header=""
    local header_line
    while IFS= read -r header_line; do
        header_line="${header_line%$'\r'}"
        [[ -z "${header_line}" ]] && break
        local h_name h_val
        h_name=$(printf '%s' "${header_line%%:*}" | tr '[:upper:]' '[:lower:]')
        h_val="${header_line#*:}"
        h_val="${h_val#" "}"
        case "${h_name}" in
            content-length) content_length="${h_val}" ;;
            accept)         accept_header="${h_val}" ;;
            mcp-session-id) session_header="${h_val}" ;;
        esac
    done

    local body=""
    if [[ "${content_length}" -gt 0 ]]; then
        body=$(dd bs=1 count="${content_length}" 2>/dev/null || true)
    fi

    case "${http_method}" in
        POST)
            handle_http_post "${body}" "${accept_header}" "${session_header}"
            ;;
        GET)
            handle_http_get "${accept_header}"
            ;;
        DELETE)
            handle_http_delete "${session_header}"
            ;;
        *)
            send_http_response "" 405 "text/plain"
            ;;
    esac
}

# Run Streamable HTTP server loop
# Supports single-request stdio HTTP framing or listening on a TCP port via nc/socat
mcp_streamable_http_server() {
    local port="${1:-${MCP_HTTP_PORT:-8080}}"
    local host="${2:-${MCP_HTTP_HOST:-127.0.0.1}}"

    # If stdin is a pipe/file with HTTP data already piped in, process it directly
    if [[ ! -t 0 ]] && [[ "${MCP_HTTP_LISTEN:-false}" != "true" ]]; then
        local first_line=""
        if IFS= read -r -t 1 first_line; then
            local stripped="${first_line%$'\r'}"
            if [[ "${stripped}" =~ ^(POST|GET|DELETE|OPTIONS|HEAD)[[:space:]] ]]; then
                { printf '%s\r\n' "${stripped}"; cat; } | handle_http_request_stream
                return 0
            elif [[ -n "${stripped}" ]]; then
                # Raw JSON body passed to streamable-http handler
                local full_body
                full_body=$(printf '%s\n' "${stripped}"; cat)
                handle_http_post "${full_body}"
                return 0
            fi
        fi
    fi

    # Otherwise, start TCP listener using socat or netcat if available
    if command -v socat >/dev/null 2>&1; then
        socat TCP-LISTEN:"${port}",bind="${host}",reuseaddr,fork EXEC:"${0} --http-worker" &
        MCP_HTTP_SERVER_PID=$!
        wait "${MCP_HTTP_SERVER_PID}"
    elif command -v nc >/dev/null 2>&1; then
        local fifo_path
        fifo_path="$(mktemp -u "${TMPDIR:-/tmp}/mcp_http_fifo.XXXXXX")"
        mkfifo "${fifo_path}"
        MCP_TEMP_FILES+=("${fifo_path}")
        while true; do
            handle_http_request_stream < "${fifo_path}" | nc -l "${host}" "${port}" > "${fifo_path}" || break
        done
    else
        echo "ERROR: Neither socat nor nc found to bind TCP port ${port} for streamable-http" >&2
        return 1
    fi
}

mcp_http_server() {
    mcp_streamable_http_server "$@"
}

# --- Transport mode detection -----------------------------------------------
get_transport_mode() {
    echo "${MCP_TRANSPORT:-stdio}"
}

# --- Main entry point -------------------------------------------------------
# Usage: ./mcp-sdk.sh [--stdio] [--http|--streamable-http] [--port PORT]
# When sourced by another script, no transport is started automatically.
mcp_main() {
    local mode
    mode=$(get_transport_mode)
    case "${mode}" in
        http|streamable-http)
            mcp_streamable_http_server "${MCP_HTTP_PORT:-8080}" "${MCP_HTTP_HOST:-127.0.0.1}"
            ;;
        stdio|*)
            mcp_stdio_server
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stdio)
                export MCP_TRANSPORT="stdio"
                ;;
            --http|--streamable-http)
                export MCP_TRANSPORT="streamable-http"
                ;;
            --listen)
                export MCP_HTTP_LISTEN="true"
                ;;
            --http-worker)
                handle_http_request_stream
                exit 0
                ;;
            --port)
                shift
                export MCP_HTTP_PORT="${1:-8080}"
                ;;
            --host)
                shift
                export MCP_HTTP_HOST="${1:-127.0.0.1}"
                ;;
            *)
                ;;
        esac
        shift
    done
    mcp_main
fi
