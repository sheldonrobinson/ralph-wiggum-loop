#!/usr/bin/env sh
# mcp-sdk.sh - Generic Shebang MCP SDK (POSIX sh compliant)
# Implementation of the Model Context Protocol (MCP) specification (latest: 2025-03-26 / 2024-11-05)
# Supports both stdio and streamable-http transports.
#
# This SDK is strictly generic and provides core MCP protocol functions usable by any
# POSIX shell-based MCP server. It contains NO application-specific logic.
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

set -eu

# Carriage-return character for stripping CRLF line endings in POSIX sh
MCP_CR="$(printf '\r')"
MCP_NL="
"

# --- Protocol constants -----------------------------------------------------
MCP_PROTOCOL_VERSION="${MCP_PROTOCOL_VERSION:-2025-03-26}"
MCP_SUPPORTED_VERSIONS="2025-03-26 2024-11-05"
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
MCP_CLEANUP_HOOKS=""
MCP_TEMP_FILES=""

# --- On-Exit & Connection Cleanup Handler -----------------------------------
# Register a custom cleanup callback function name to run on exit
mcp_register_cleanup() {
    _hook="${1:-}"
    if [ -n "${_hook}" ]; then
        if [ -z "${MCP_CLEANUP_HOOKS}" ]; then
            MCP_CLEANUP_HOOKS="${_hook}"
        else
            MCP_CLEANUP_HOOKS="${MCP_CLEANUP_HOOKS} ${_hook}"
        fi
    fi
}

# Track a temporary file/FIFO for automatic removal on exit
mcp_register_temp_file() {
    _tmpf="${1:-}"
    if [ -n "${_tmpf}" ]; then
        if [ -z "${MCP_TEMP_FILES}" ]; then
            MCP_TEMP_FILES="${_tmpf}"
        else
            MCP_TEMP_FILES="${MCP_TEMP_FILES}${MCP_NL}${_tmpf}"
        fi
    fi
}

# Close active MCP transport connections and release resources
mcp_close_connection() {
    # Stop background HTTP listener if running
    if [ -n "${MCP_HTTP_SERVER_PID:-}" ]; then
        if kill -0 "${MCP_HTTP_SERVER_PID}" 2>/dev/null; then
            kill "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
            wait "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
        fi
        MCP_HTTP_SERVER_PID=""
    fi

    # Remove any temporary files/FIFOs created by the transport
    if [ -n "${MCP_TEMP_FILES}" ]; then
        _old_ifs="${IFS}"
        IFS="${MCP_NL}"
        for _f in ${MCP_TEMP_FILES}; do
            if [ -n "${_f}" ] && [ -e "${_f}" ]; then
                rm -rf "${_f}" 2>/dev/null || true
            fi
        done
        IFS="${_old_ifs}"
        MCP_TEMP_FILES=""
    fi

    MCP_INITIALIZED="false"
    MCP_SESSION_ID=""
}

# Trap handler invoked on EXIT, INT, TERM, HUP
mcp_on_exit() {
    _exit_code=$?
    trap - EXIT INT TERM HUP
    if [ "${MCP_CLEANUP_DONE}" = "true" ]; then
        return "${_exit_code}"
    fi
    MCP_CLEANUP_DONE="true"

    # Run registered consumer cleanup hooks if any
    if [ -n "${MCP_CLEANUP_HOOKS}" ]; then
        for _hook in ${MCP_CLEANUP_HOOKS}; do
            if command -v "${_hook}" >/dev/null 2>&1; then
                "${_hook}" || true
            fi
        done
    fi

    # Close connections and clean up transport resources
    mcp_close_connection || true

    return "${_exit_code}"
}

mcp_on_signal() {
    _sig="${1:-TERM}"
    _code="${2:-143}"
    mcp_on_exit || true
    exit "${_code}"
}

trap mcp_on_exit EXIT
trap 'mcp_on_signal INT 130' INT
trap 'mcp_on_signal TERM 143' TERM
trap 'mcp_on_signal HUP 129' HUP

# --- JSON-RPC 2.0 helpers ---------------------------------------------------
json_escape() {
    printf '%s' "${1:-}" | jq -Rs .
}

is_json_number() {
    case "${1:-}" in
        ''|'-') return 1 ;;
        -*)
            _num="${1#-}"
            ;;
        *)
            _num="${1}"
            ;;
    esac
    case "${_num}" in
        ''|*[!0-9.]*|*.*.*) return 1 ;;
        .*) return 1 ;;
        *.) return 1 ;;
        *) return 0 ;;
    esac
}

# JSON-RPC 2.0 response constructor
# Usage: json_response <id> <result_json> [error_json]
json_response() {
    _jr_id="${1:-null}"
    _jr_result="${2:-"{}"}"
    _jr_error="${3:-}"

    if [ -z "${_jr_id}" ] || [ "${_jr_id}" = "null" ]; then
        _jr_id_expr="null"
    elif is_json_number "${_jr_id}"; then
        _jr_id_expr="${_jr_id}"
    else
        case "${_jr_id}" in
            \"*\")
                _jr_id_expr="${_jr_id}"
                ;;
            *)
                _jr_id_expr=$(printf '%s' "${_jr_id}" | jq -Rs .)
                ;;
        esac
    fi

    if [ -n "${_jr_error}" ]; then
        if printf '%s' "${_jr_error}" | jq -e . >/dev/null 2>&1; then
            _jr_payload=$(jq -cn \
                --argjson id "${_jr_id_expr}" \
                --argjson err "${_jr_error}" \
                '{jsonrpc:"2.0", id:$id, error:$err}')
        else
            _jr_payload=$(jq -cn \
                --argjson id "${_jr_id_expr}" \
                --arg msg "${_jr_error}" \
                '{jsonrpc:"2.0", id:$id, error:{code:-32603, message:$msg}}')
        fi
    else
        _jr_result_json="{}"
        if [ -n "${_jr_result}" ]; then
            if printf '%s' "${_jr_result}" | jq -e . >/dev/null 2>&1; then
                _jr_result_json="${_jr_result}"
            else
                _jr_result_json=$(printf '%s' "${_jr_result}" | jq -Rs '{content:[{type:"text",text:.}]}')
            fi
        fi
        _jr_payload=$(jq -cn \
            --argjson id "${_jr_id_expr}" \
            --argjson res "${_jr_result_json}" \
            '{jsonrpc:"2.0", id:$id, result:$res}')
    fi
    printf '%s\n' "${_jr_payload}"
}

# JSON-RPC 2.0 error object constructor
# Usage: mcp_error <code> <message> [data_json]
mcp_error() {
    _me_code="${1:--32603}"
    _me_message="${2:-Internal error}"
    _me_data="${3:-null}"
    if [ -z "${_me_data}" ] || [ "${_me_data}" = "null" ]; then
        jq -cn --argjson code "${_me_code}" --arg message "${_me_message}" \
            '{code:$code, message:$message}'
    else
        if ! printf '%s' "${_me_data}" | jq -e . >/dev/null 2>&1; then
            _me_data=$(printf '%s' "${_me_data}" | jq -Rs .)
        fi
        jq -cn --argjson code "${_me_code}" --arg message "${_me_message}" --argjson data "${_me_data}" \
            '{code:$code, message:$message, data:$data}'
    fi
}

# Format a tool result per MCP spec (content array with text item + optional structured/raw fields)
# Usage: mcp_tool_result <text_or_json> [is_error]
mcp_tool_result() {
    _mtr_content="${1:-}"
    _mtr_is_error="${2:-false}"
    jq -cn --arg text "${_mtr_content}" --argjson isError "${_mtr_is_error}" \
        '{content:[{type:"text", text:$text}], isError:$isError}'
}

# Validate and parse incoming JSON-RPC 2.0 message
# Usage: mcp_parse_message <message>
mcp_parse_message() {
    _mpm_message="${1:-}"
    if ! printf '%s' "${_mpm_message}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf 'VALID=false\nIS_NOTIFICATION=false\nID=null\nMETHOD=\nPARAMS={}\n'
        return 0
    fi

    _mpm_jsonrpc=$(printf '%s' "${_mpm_message}" | jq -r '.jsonrpc // ""' 2>/dev/null || echo "")
    _mpm_has_id=$(printf '%s' "${_mpm_message}" | jq -r 'has("id")' 2>/dev/null || echo "false")
    _mpm_id=$(printf '%s' "${_mpm_message}" | jq -r 'if .id == null then "null" else (.id | tostring) end' 2>/dev/null || echo "null")
    _mpm_method=$(printf '%s' "${_mpm_message}" | jq -r 'if (.method | type) == "string" then .method else "" end' 2>/dev/null || echo "")
    _mpm_params=$(printf '%s' "${_mpm_message}" | jq -c '.params // {}' 2>/dev/null || echo "{}")

    if [ "${_mpm_has_id}" = "false" ]; then
        _mpm_is_notification="true"
    else
        _mpm_is_notification="false"
    fi

    printf 'VALID=true\nJSONRPC=%s\nIS_NOTIFICATION=%s\nID=%s\nMETHOD=%s\nPARAMS=%s\n' \
        "${_mpm_jsonrpc}" "${_mpm_is_notification}" "${_mpm_id}" "${_mpm_method}" "${_mpm_params}"
}

# ============================================================================
# MCP METHOD HANDLERS (generic protocol handlers; overridable by consumers)
# ============================================================================

# Handle MCP initialize request
handle_initialize() {
    _hi_id="${1}"
    _hi_params="${2:-"{}"}"

    _hi_client_version=$(printf '%s' "${_hi_params}" | jq -r '.protocolVersion // ""' 2>/dev/null || echo "")
    _hi_negotiated="${MCP_PROTOCOL_VERSION}"

    if [ -n "${_hi_client_version}" ]; then
        for _v in ${MCP_SUPPORTED_VERSIONS}; do
            if [ "${_v}" = "${_hi_client_version}" ]; then
                _hi_negotiated="${_hi_client_version}"
                break
            fi
        done
    fi

    MCP_INITIALIZED="true"

    _hi_caps=$(jq -cn '{tools:{}}')
    _hi_info=$(jq -cn --arg name "${MCP_SERVER_NAME}" --arg version "${MCP_SERVER_VERSION}" \
        '{name:$name, version:$version}')
    _hi_res=$(jq -cn \
        --arg proto "${_hi_negotiated}" \
        --argjson caps "${_hi_caps}" \
        --argjson info "${_hi_info}" \
        '{protocolVersion:$proto, capabilities:$caps, serverInfo:$info}')
    json_response "${_hi_id}" "${_hi_res}"
}

# Handle notifications/initialized (and legacy initialized) notification
handle_initialized() {
    MCP_INITIALIZED="true"
    return 0
}

# Handle MCP ping request
handle_ping() {
    json_response "${1}" "{}"
}

# Default generic tools/list handler (consumers can override handle_tools_list or handle_list_tools)
handle_tools_list() {
    _htl_id="${1}"
    _htl_params="${2:-"{}"}"

    if command -v handle_list_tools >/dev/null 2>&1; then
        handle_list_tools "${_htl_id}" "${_htl_params}"
        return 0
    fi

    _htl_res=$(jq -cn '{tools:[]}')
    json_response "${_htl_id}" "${_htl_res}"
}

# Default generic tools/call handler (consumers can override handle_tools_call)
handle_tools_call() {
    _htc_id="${1}"
    _htc_params="${2:-"{}"}"

    _htc_name=$(printf '%s' "${_htc_params}" | jq -r '.name // ""' 2>/dev/null || echo "")
    if [ -z "${_htc_name}" ]; then
        _htc_err=$(mcp_error -32602 "Invalid params: missing tool name")
        json_response "${_htc_id}" "" "${_htc_err}"
        return 0
    fi

    _htc_err=$(mcp_error -32601 "Tool not found: ${_htc_name}")
    json_response "${_htc_id}" "" "${_htc_err}"
}

# Generic JSON-RPC 2.0 message dispatcher
mcp_dispatch_message() {
    _mdm_line="${1:-}"
    if [ -z "${_mdm_line}" ]; then
        return 0
    fi

    if ! printf '%s' "${_mdm_line}" | jq -e . >/dev/null 2>&1; then
        _mdm_err=$(mcp_error -32700 "Parse error")
        json_response "null" "" "${_mdm_err}"
        return 0
    fi

    _mdm_type=$(printf '%s' "${_mdm_line}" | jq -r 'type' 2>/dev/null || echo "")
    if [ "${_mdm_type}" = "array" ]; then
        _mdm_len=$(printf '%s' "${_mdm_line}" | jq 'length')
        if [ "${_mdm_len}" -eq 0 ]; then
            _mdm_err=$(mcp_error -32600 "Invalid Request: empty batch")
            json_response "null" "" "${_mdm_err}"
            return 0
        fi
        _mdm_responses=""
        _mdm_idx=0
        while [ "${_mdm_idx}" -lt "${_mdm_len}" ]; do
            _mdm_item=$(printf '%s' "${_mdm_line}" | jq -c ".[${_mdm_idx}]")
            _mdm_item_resp=$(mcp_dispatch_single "${_mdm_item}")
            if [ -n "${_mdm_item_resp}" ]; then
                if [ -z "${_mdm_responses}" ]; then
                    _mdm_responses="${_mdm_item_resp}"
                else
                    _mdm_responses="${_mdm_responses}${MCP_NL}${_mdm_item_resp}"
                fi
            fi
            _mdm_idx=$((_mdm_idx + 1))
        done
        if [ -n "${_mdm_responses}" ]; then
            printf '%s\n' "${_mdm_responses}" | jq -cs '.'
        fi
        return 0
    elif [ "${_mdm_type}" != "object" ]; then
        _mdm_err=$(mcp_error -32600 "Invalid Request")
        json_response "null" "" "${_mdm_err}"
        return 0
    fi

    mcp_dispatch_single "${_mdm_line}"
}

mcp_dispatch_single() {
    _mds_message="${1}"
    _mds_parse=$(mcp_parse_message "${_mds_message}")

    _mds_valid=$(printf '%s\n' "${_mds_parse}" | grep '^VALID=' | cut -d= -f2-)
    _mds_jsonrpc=$(printf '%s\n' "${_mds_parse}" | grep '^JSONRPC=' | cut -d= -f2-)
    _mds_is_notif=$(printf '%s\n' "${_mds_parse}" | grep '^IS_NOTIFICATION=' | cut -d= -f2-)
    _mds_id=$(printf '%s\n' "${_mds_parse}" | grep '^ID=' | cut -d= -f2-)
    _mds_method=$(printf '%s\n' "${_mds_parse}" | grep '^METHOD=' | cut -d= -f2-)
    _mds_params=$(printf '%s\n' "${_mds_parse}" | grep '^PARAMS=' | cut -d= -f2-)

    if [ "${_mds_valid}" != "true" ] || [ "${_mds_jsonrpc}" != "2.0" ]; then
        _mds_err=$(mcp_error -32600 "Invalid Request")
        json_response "${_mds_id}" "" "${_mds_err}"
        return 0
    fi

    if [ -z "${_mds_method}" ]; then
        if printf '%s' "${_mds_message}" | jq -e 'has("result") or has("error")' >/dev/null 2>&1; then
            return 0
        fi
        _mds_err=$(mcp_error -32600 "Invalid Request: missing method")
        json_response "${_mds_id}" "" "${_mds_err}"
        return 0
    fi

    case "${_mds_method}" in
        initialize)
            handle_initialize "${_mds_id}" "${_mds_params}"
            ;;
        notifications/initialized|initialized)
            handle_initialized
            ;;
        notifications/*)
            return 0
            ;;
        ping)
            handle_ping "${_mds_id}"
            ;;
        tools/list)
            handle_tools_list "${_mds_id}" "${_mds_params}"
            ;;
        tools/call)
            handle_tools_call "${_mds_id}" "${_mds_params}"
            ;;
        *)
            if command -v mcp_custom_method_handler >/dev/null 2>&1; then
                mcp_custom_method_handler "${_mds_id}" "${_mds_method}" "${_mds_params}" "${_mds_is_notif}"
                return 0
            fi
            if [ "${_mds_is_notif}" != "true" ] && [ "${_mds_id}" != "null" ] && [ -n "${_mds_id}" ]; then
                _mds_err=$(mcp_error -32601 "Method not found: ${_mds_method}")
                json_response "${_mds_id}" "" "${_mds_err}"
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

mcp_stdio_server() {
    while IFS= read -r _stdio_line || [ -n "${_stdio_line}" ]; do
        _stdio_line="${_stdio_line%"${MCP_CR}"}"
        if [ -z "${_stdio_line}" ]; then
            continue
        fi
        mcp_dispatch_message "${_stdio_line}"
    done
}

# ============================================================================
# TRANSPORT: STREAMABLE-HTTP (MCP 2025-03-26 specification)
# ============================================================================

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
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        _rand=$(awk 'BEGIN{srand(); printf "%d", int(rand()*100000)}' 2>/dev/null || echo "$$")
        printf 'mcp-%s-%s-%s\n' "$(date +%s)" "$$" "${_rand}"
    fi
}

extract_jsonrpc_from_post() {
    _ejp_body="${1:-}"
    if [ -z "${_ejp_body}" ]; then
        echo ""
        return 0
    fi
    if printf '%s' "${_ejp_body}" | jq -e . >/dev/null 2>&1; then
        printf '%s' "${_ejp_body}" | jq -c '.'
    else
        echo ""
    fi
}

send_http_response() {
    _shr_body="${1:-}"
    _shr_status="${2:-200}"
    _shr_ctype="${3:-application/json}"
    _shr_sid="${4:-${MCP_SESSION_ID:-}}"

    case "${_shr_status}" in
        200) _shr_text="OK" ;;
        202) _shr_text="Accepted" ;;
        204) _shr_text="No Content" ;;
        400) _shr_text="Bad Request" ;;
        404) _shr_text="Not Found" ;;
        405) _shr_text="Method Not Allowed" ;;
        406) _shr_text="Not Acceptable" ;;
        500) _shr_text="Internal Server Error" ;;
        *)   _shr_text="OK" ;;
    esac

    _shr_len=$(printf '%s' "${_shr_body}" | wc -c | tr -d ' ')

    printf 'HTTP/1.1 %s %s\r\n' "${_shr_status}" "${_shr_text}"
    if [ -n "${_shr_ctype}" ] && [ "${_shr_len}" -gt 0 ]; then
        printf 'Content-Type: %s\r\n' "${_shr_ctype}"
    fi
    if [ -n "${_shr_sid}" ]; then
        printf 'Mcp-Session-Id: %s\r\n' "${_shr_sid}"
    fi
    printf 'Cache-Control: no-cache\r\n'
    printf 'Connection: close\r\n'
    printf 'Content-Length: %d\r\n' "${_shr_len}"
    printf '\r\n'
    if [ "${_shr_len}" -gt 0 ]; then
        printf '%s' "${_shr_body}"
    fi
}

send_http_sse_response() {
    _shs_json="${1:-}"
    _shs_status="${2:-200}"
    _shs_sid="${3:-${MCP_SESSION_ID:-}}"
    _shs_body=$(printf 'event: message\ndata: %s\n\n' "${_shs_json}")
    send_http_response "${_shs_body}" "${_shs_status}" "text/event-stream" "${_shs_sid}"
}

handle_http_post() {
    _hhp_body="${1:-}"
    _hhp_accept="${2:-application/json, text/event-stream}"
    _hhp_req_sid="${3:-}"

    if ! printf '%s' "${_hhp_body}" | jq -e . >/dev/null 2>&1; then
        _hhp_err=$(json_response "null" "" "$(mcp_error -32700 "Parse error")")
        send_http_response "${_hhp_err}" 400 "application/json"
        return 0
    fi

    _hhp_msg=$(extract_jsonrpc_from_post "${_hhp_body}")
    if [ -z "${_hhp_msg}" ]; then
        _hhp_err=$(json_response "null" "" "$(mcp_error -32600 "Invalid JSON-RPC message")")
        send_http_response "${_hhp_err}" 400 "application/json"
        return 0
    fi

    _hhp_method=$(printf '%s' "${_hhp_msg}" | jq -r 'if type=="object" then (.method // "") else "" end' 2>/dev/null || echo "")
    if [ "${_hhp_method}" = "initialize" ] && [ -z "${MCP_SESSION_ID}" ]; then
        MCP_SESSION_ID=$(mcp_generate_session_id)
    elif [ -n "${MCP_SESSION_ID}" ] && [ -n "${_hhp_req_sid}" ] && [ "${_hhp_req_sid}" != "${MCP_SESSION_ID}" ]; then
        _hhp_err=$(json_response "null" "" "$(mcp_error -32600 "Invalid or expired Mcp-Session-Id")")
        send_http_response "${_hhp_err}" 404 "application/json"
        return 0
    fi

    _hhp_resp=$(mcp_dispatch_message "${_hhp_msg}")

    if [ -z "${_hhp_resp}" ]; then
        send_http_response "" 202 "" "${MCP_SESSION_ID}"
        return 0
    fi

    # Check if accept_header contains text/event-stream and NOT application/json using POSIX parameter expansion
    if [ "${_hhp_accept#*text/event-stream}" != "${_hhp_accept}" ] && [ "${_hhp_accept#*application/json}" = "${_hhp_accept}" ]; then
        send_http_sse_response "${_hhp_resp}" 200 "${MCP_SESSION_ID}"
    else
        send_http_response "${_hhp_resp}" 200 "application/json" "${MCP_SESSION_ID}"
    fi
}

handle_http_get() {
    _hhg_accept="${1:-}"
    if [ "${_hhg_accept#*text/event-stream}" != "${_hhg_accept}" ]; then
        _hhg_body="$(printf ': streamable-http sse stream open\n\n')"
        send_http_response "${_hhg_body}" 200 "text/event-stream" "${MCP_SESSION_ID}"
    else
        send_http_response "" 405 "text/plain" "${MCP_SESSION_ID}"
    fi
}

handle_http_delete() {
    _hhd_req_sid="${1:-}"
    if [ -n "${MCP_SESSION_ID}" ] && [ -n "${_hhd_req_sid}" ] && [ "${_hhd_req_sid}" != "${MCP_SESSION_ID}" ]; then
        send_http_response "" 404 "text/plain"
        return 0
    fi
    MCP_SESSION_ID=""
    MCP_INITIALIZED="false"
    send_http_response "" 200 "text/plain"
}

handle_http_request_stream() {
    _hhrs_req_line=""
    if ! IFS= read -r _hhrs_req_line; then
        return 1
    fi
    _hhrs_req_line="${_hhrs_req_line%"${MCP_CR}"}"
    if [ -z "${_hhrs_req_line}" ]; then
        return 1
    fi

    # Extract method, path, and version using POSIX parameter expansion
    _hhrs_method="${_hhrs_req_line%% *}"
    _hhrs_rest="${_hhrs_req_line#* }"
    _hhrs_path="${_hhrs_rest%% *}"

    _hhrs_clen=0
    _hhrs_accept="application/json, text/event-stream"
    _hhrs_session=""
    while IFS= read -r _hhrs_hline; do
        _hhrs_hline="${_hhrs_hline%"${MCP_CR}"}"
        if [ -z "${_hhrs_hline}" ]; then
            break
        fi
        _hhrs_hname=$(printf '%s' "${_hhrs_hline%%:*}" | tr '[:upper:]' '[:lower:]')
        _hhrs_hval="${_hhrs_hline#*:}"
        _hhrs_hval="${_hhrs_hval#" "}"
        case "${_hhrs_hname}" in
            content-length) _hhrs_clen="${_hhrs_hval}" ;;
            accept)         _hhrs_accept="${_hhrs_hval}" ;;
            mcp-session-id) _hhrs_session="${_hhrs_hval}" ;;
        esac
    done

    _hhrs_body=""
    if [ "${_hhrs_clen}" -gt 0 ]; then
        _hhrs_body=$(dd bs=1 count="${_hhrs_clen}" 2>/dev/null || true)
    fi

    case "${_hhrs_method}" in
        POST)
            handle_http_post "${_hhrs_body}" "${_hhrs_accept}" "${_hhrs_session}"
            ;;
        GET)
            handle_http_get "${_hhrs_accept}"
            ;;
        DELETE)
            handle_http_delete "${_hhrs_session}"
            ;;
        *)
            send_http_response "" 405 "text/plain"
            ;;
    esac
}

mcp_streamable_http_server() {
    _mshs_port="${1:-${MCP_HTTP_PORT:-8080}}"
    _mshs_host="${2:-${MCP_HTTP_HOST:-127.0.0.1}}"

    if [ ! -t 0 ] && [ "${MCP_HTTP_LISTEN:-false}" != "true" ]; then
        _mshs_first=""
        if IFS= read -r _mshs_first; then
            _mshs_stripped="${_mshs_first%"${MCP_CR}"}"
            case "${_mshs_stripped}" in
                "POST "*|"GET "*|"DELETE "*|"OPTIONS "*|"HEAD "*)
                    { printf '%s\r\n' "${_mshs_stripped}"; cat; } | handle_http_request_stream
                    return 0
                    ;;
                *)
                    if [ -n "${_mshs_stripped}" ]; then
                        _mshs_full=$(printf '%s\n' "${_mshs_stripped}"; cat)
                        handle_http_post "${_mshs_full}"
                        return 0
                    fi
                    ;;
            esac
        fi
    fi

    if command -v socat >/dev/null 2>&1; then
        socat TCP-LISTEN:"${_mshs_port}",bind="${_mshs_host}",reuseaddr,fork EXEC:"sh ${0} --http-worker" &
        MCP_HTTP_SERVER_PID=$!
        wait "${MCP_HTTP_SERVER_PID}"
    elif command -v nc >/dev/null 2>&1; then
        _mshs_fifo="$(mktemp -u "${TMPDIR:-/tmp}/mcp_http_fifo.XXXXXX")"
        mkfifo "${_mshs_fifo}"
        mcp_register_temp_file "${_mshs_fifo}"
        while true; do
            handle_http_request_stream < "${_mshs_fifo}" | nc -l "${_mshs_host}" "${_mshs_port}" > "${_mshs_fifo}" || break
        done
    else
        echo "ERROR: Neither socat nor nc found to bind TCP port ${_mshs_port} for streamable-http" >&2
        return 1
    fi
}

mcp_http_server() {
    mcp_streamable_http_server "$@"
}

get_transport_mode() {
    echo "${MCP_TRANSPORT:-stdio}"
}

mcp_main() {
    _mm_mode=$(get_transport_mode)
    case "${_mm_mode}" in
        http|streamable-http)
            mcp_streamable_http_server "${MCP_HTTP_PORT:-8080}" "${MCP_HTTP_HOST:-127.0.0.1}"
            ;;
        stdio|*)
            mcp_stdio_server
            ;;
    esac
}

if [ "${MCP_SDK_SOURCED:-false}" != "true" ]; then
    case "${0##*/}" in
        mcp-sdk.sh|mcp-sdk)
            while [ $# -gt 0 ]; do
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
            ;;
    esac
fi
