#!/usr/bin/env sh
# ralph-wiggum-loop.sh - Ralph Loop Agent Plugin (POSIX sh compliant: MCP Server + CLI Orchestration)
# Cross-platform implementation of the Ralph Loop iterative development technique.
# Sources generic mcp-sdk.sh for shared MCP protocol utilities.

set -eu

# =============================================================================
# ENSURE jq AND STANDARD TOOLPATHS ARE IN $PATH (USING POSIX PARAMETER EXPANSION)
# =============================================================================
# Only edit PATH if jq is not already found in PATH; uses ${PATH#*dir} substring
# check (per POSIX shell cheat sheet / TLDP) to avoid duplicate PATH entries.
if ! command -v jq >/dev/null 2>&1; then
    for _ralph_dir in /opt/homebrew/bin /usr/local/bin "${HOME:-}/.local/bin"; do
        if [ -n "${_ralph_dir}" ] && [ -d "${_ralph_dir}" ] && [ "${PATH#*${_ralph_dir}}" = "${PATH}" ]; then
            PATH="${_ralph_dir}:${PATH}"
        fi
    done
    export PATH
    unset _ralph_dir
fi

# =============================================================================
# SOURCE THE GENERIC MCP SDK
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_SERVER_NAME="ralph-wiggum-loop"
MCP_SERVER_VERSION="1.1.0"
MCP_SDK_SOURCED="true"
. "${SCRIPT_DIR}/mcp-sdk.sh"

# =============================================================================
# CONFIGURATION (from environment variables with defaults, supporting Agent Plugins PLUGIN_ROOT & PLUGIN_DATA)
# =============================================================================
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
WORKSPACE="${WORKSPACE:-${PLUGIN_ROOT}}"
RALPH_STATE_BASE="${RALPH_STATE_BASE:-${PLUGIN_DATA:+${PLUGIN_DATA}/state}}"
RALPH_STATE_BASE="${RALPH_STATE_BASE:-${WORKSPACE}/.ralph}"
RALPH_RECIPE_DIR="${RALPH_RECIPE_DIR:-${PLUGIN_ROOT}/recipes}"
SAFE_COMMANDS="ls pwd echo date cat mkdir rm cp mv jq"
CMD_TIMEOUT=30

# Rate limit & retry configuration
RALPH_MAX_RETRIES="${RALPH_MAX_RETRIES:-3}"
RALPH_INITIAL_BACKOFF="${RALPH_INITIAL_BACKOFF:-5}"
RALPH_THROTTLE_DELAY="${RALPH_THROTTLE_DELAY:-0}"

# Environment variable defaults
WORKER_MODEL="${RALPH_WORKER_MODEL:-}"
WORKER_PROVIDER="${RALPH_WORKER_PROVIDER:-}"
WORKER_AGENT="${RALPH_WORKER_AGENT:-goose}"
REVIEWER_MODEL="${RALPH_REVIEWER_MODEL:-}"
REVIEWER_PROVIDER="${RALPH_REVIEWER_PROVIDER:-}"
REVIEWER_AGENT="${RALPH_REVIEWER_AGENT:-goose}"
MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-10}"
WORK_GUIDELINES="${RALPH_WORK_GUIDELINES:-${RALPH_RECIPE_DIR}/ralph-work.yaml}"
REVIEW_GUIDELINES="${RALPH_REVIEW_GUIDELINES:-${RALPH_RECIPE_DIR}/ralph-review.yaml}"
MONITOR_MODEL="${RALPH_MONITOR_MODEL:-}"
MONITOR_PROVIDER="${RALPH_MONITOR_PROVIDER:-${RALPH_MONITON_PROVIDER:-}}"
MONITOR_AGENT="${RALPH_MONITOR_AGENT:-goose}"

CLI_TASK=""
CLI_SESSION_ID=""

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq is required but not installed"}}' >&2
    exit 1
fi

# =============================================================================
# SESSION STATE MANAGEMENT
# =============================================================================
get_state_dir() {
    echo "${RALPH_STATE_BASE}/${1:-default}"
}

get_state_file() {
    echo "$(get_state_dir "${1:-default}")/${2}"
}

ensure_state_dir() {
    mkdir -p "$(get_state_dir "${1:-default}")"
}

# Check if output contains rate limit / quota / resource errors
is_rate_limit_error() {
    if printf '%s\n' "${1:-}" | grep -iqE "(rate_limit|rate limit|429|quota_exceeded|quota exceeded|resource_exhausted|resource exhausted|too many requests|overloaded|throttled)"; then
        return 0
    else
        return 1
    fi
}

# Rate throttling helper
apply_rate_throttling() {
    _throttle_delay="${1:-${RALPH_THROTTLE_DELAY}}"
    if [ "${_throttle_delay}" -gt 0 ]; then
        sleep "${_throttle_delay}"
    fi
}

# Retry helper with exponential backoff and rate throttling for LLM execution
execute_llm_with_retry() {
    _elr_role="$1"
    _elr_session="$2"
    shift 2

    _elr_max_retries="${RALPH_MAX_RETRIES}"
    _elr_initial_backoff="${RALPH_INITIAL_BACKOFF}"
    _elr_throttle_delay="${RALPH_THROTTLE_DELAY}"

    if [ -n "${_elr_session}" ] && [ "${_elr_session}" != "default" ]; then
        _elr_cfg=$(get_config "${_elr_session}")
        if [ -n "${_elr_cfg}" ]; then
            _elr_max_retries=$(printf '%s\n' "${_elr_cfg}" | jq -r '.maxRetries // 3')
            _elr_initial_backoff=$(printf '%s\n' "${_elr_cfg}" | jq -r '.initialBackoff // 5')
            _elr_throttle_delay=$(printf '%s\n' "${_elr_cfg}" | jq -r '.throttleDelay // 0')
        fi
    fi

    apply_rate_throttling "${_elr_throttle_delay}"

    _elr_attempt=1
    _elr_backoff="${_elr_initial_backoff}"
    _elr_max_attempts=$((_elr_max_retries + 1))
    _elr_output=""
    _elr_code=0

    while [ "${_elr_attempt}" -le "${_elr_max_attempts}" ]; do
        set +e
        _elr_output=$("$@" 2>&1)
        _elr_code=$?
        set -e

        if [ "${_elr_code}" -eq 0 ] && [ -n "${_elr_output}" ] && ! is_rate_limit_error "${_elr_output}"; then
            printf '%s\n' "${_elr_output}"
            return 0
        fi

        if is_rate_limit_error "${_elr_output}" || [ "${_elr_code}" -ne 0 ]; then
            if [ "${_elr_attempt}" -lt "${_elr_max_attempts}" ]; then
                echo "[WARN]  [${_elr_role}] Rate limit / resource constraint detected on attempt ${_elr_attempt}/${_elr_max_retries}. Retrying in ${_elr_backoff}s..." >&2
                sleep "${_elr_backoff}"
                _elr_backoff=$((_elr_backoff * 2))
                _elr_attempt=$((_elr_attempt + 1))
                continue
            else
                echo "[WARN] [${_elr_role}] Rate limit / quota error persisted after ${_elr_max_retries} retries." >&2
                if is_rate_limit_error "${_elr_output}"; then
                    echo "RATE_LIMIT_EXCEEDED: ${_elr_output}"
                fi
                return 1
            fi
        fi

        printf '%s\n' "${_elr_output}"
        return 0
    done

    return 1
}

# =============================================================================
# CONFIG MANAGEMENT
# =============================================================================
set_config() {
    _sc_session="${1}"
    _sc_w_model="${2:-}"
    _sc_w_prov="${3:-}"
    _sc_r_model="${4:-}"
    _sc_r_prov="${5:-}"
    _sc_max_iter="${6:-10}"
    _sc_enforced="${7:-true}"
    _sc_w_agent="${8:-goose}"
    _sc_r_agent="${9:-goose}"
    _sc_w_guide="${10:-}"
    _sc_r_guide="${11:-}"
    _sc_m_model="${12:-}"
    _sc_m_prov="${13:-}"
    _sc_m_agent="${14:-goose}"
    _sc_backoff="${15:-5}"
    _sc_throttle="${16:-0}"
    _sc_retries="${17:-3}"

    ensure_state_dir "${_sc_session}"
    _sc_file="$(get_state_file "${_sc_session}" "config.json")"

    jq -n \
        --arg workerModel "${_sc_w_model}" \
        --arg workerProvider "${_sc_w_prov}" \
        --arg workerAgent "${_sc_w_agent}" \
        --arg reviewerModel "${_sc_r_model}" \
        --arg reviewerProvider "${_sc_r_prov}" \
        --arg reviewerAgent "${_sc_r_agent}" \
        --arg monitorModel "${_sc_m_model}" \
        --arg monitorProvider "${_sc_m_prov}" \
        --arg monitorAgent "${_sc_m_agent}" \
        --argjson maxIterations "${_sc_max_iter}" \
        --argjson initialBackoff "${_sc_backoff}" \
        --argjson throttleDelay "${_sc_throttle}" \
        --argjson maxRetries "${_sc_retries}" \
        --argjson crossModelReviewEnforced "${_sc_enforced}" \
        --arg workGuidelines "${_sc_w_guide}" \
        --arg reviewGuidelines "${_sc_r_guide}" \
        --arg configuredAt "$(date -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            workerModel: $workerModel,
            workerProvider: $workerProvider,
            workerAgent: $workerAgent,
            reviewerModel: $reviewerModel,
            reviewerProvider: $reviewerProvider,
            reviewerAgent: $reviewerAgent,
            monitorModel: $monitorModel,
            monitorProvider: $monitorProvider,
            monitorAgent: $monitorAgent,
            maxIterations: $maxIterations,
            initialBackoff: $initialBackoff,
            throttleDelay: $throttleDelay,
            maxRetries: $maxRetries,
            crossModelReviewEnforced: $crossModelReviewEnforced,
            workGuidelines: $workGuidelines,
            reviewGuidelines: $reviewGuidelines,
            configuredAt: $configuredAt
        }' > "${_sc_file}"
}

get_config() {
    _gc_file="$(get_state_file "${1:-default}" "config.json")"
    if [ -f "${_gc_file}" ]; then
        cat "${_gc_file}"
    else
        echo ""
    fi
}

validate_cross_model() {
    _vcm_cfg=$(get_config "${1:-default}")
    if [ -z "${_vcm_cfg}" ]; then
        echo '{"valid":true}'
        return
    fi
    _vcm_enforced=$(printf '%s\n' "${_vcm_cfg}" | jq -r '.crossModelReviewEnforced // true')
    if [ "${_vcm_enforced}" != "true" ]; then
        echo '{"valid":true}'
        return
    fi
    _vcm_wm=$(printf '%s\n' "${_vcm_cfg}" | jq -r '.workerModel // empty')
    _vcm_wp=$(printf '%s\n' "${_vcm_cfg}" | jq -r '.workerProvider // empty')
    _vcm_rm=$(printf '%s\n' "${_vcm_cfg}" | jq -r '.reviewerModel // empty')
    _vcm_rp=$(printf '%s\n' "${_vcm_cfg}" | jq -r '.reviewerProvider // empty')

    if [ -n "${_vcm_wm}" ] && [ -n "${_vcm_rm}" ] && \
       [ "${_vcm_wm}" = "${_vcm_rm}" ] && \
       [ "${_vcm_wp}" = "${_vcm_rp}" ]; then
        echo '{"valid":false,"warning":"Worker and reviewer are the same model/provider. Cross-model review requires different models."}'
    else
        echo '{"valid":true}'
    fi
}

# =============================================================================
# ADAPTIVE PROFILE SWITCHING
# =============================================================================
resolve_profile_path() {
    _rpp_name="${1}"
    for _rpp_cand in \
        "${PLUGIN_ROOT:-}/profiles/${_rpp_name}.json" \
        "${PLUGIN_ROOT:-}/profiles/${_rpp_name}" \
        "${WORKSPACE}/profiles/${_rpp_name}.json" \
        "${WORKSPACE}/profiles/${_rpp_name}" \
        "${WORKSPACE}/${_rpp_name}" \
        "${_rpp_name}" \
        "${SCRIPT_DIR}/../profiles/${_rpp_name}.json" \
        "${SCRIPT_DIR}/../profiles/${_rpp_name}" \
        "${SCRIPT_DIR}/profiles/${_rpp_name}.json" \
        "${SCRIPT_DIR}/profiles/${_rpp_name}"
    do
        if [ -f "${_rpp_cand}" ]; then
            echo "${_rpp_cand}"
            return 0
        fi
    done
    return 1
}

apply_profile() {
    _ap_session="${1}"
    _ap_name="${2}"

    if ! _ap_path="$(resolve_profile_path "${_ap_name}")"; then
        echo "[ERROR] Profile file not found: ${_ap_name}" >&2
        return 1
    fi

    ensure_state_dir "${_ap_session}"

    _ap_wm=$(jq -r '.workerModel // empty' "${_ap_path}")
    _ap_wp=$(jq -r '.workerProvider // empty' "${_ap_path}")
    _ap_wa=$(jq -r '.workerAgent // "goose"' "${_ap_path}")
    _ap_rm=$(jq -r '.reviewerModel // empty' "${_ap_path}")
    _ap_rp=$(jq -r '.reviewerProvider // empty' "${_ap_path}")
    _ap_ra=$(jq -r '.reviewerAgent // "goose"' "${_ap_path}")
    _ap_mm=$(jq -r '.monitorModel // empty' "${_ap_path}")
    _ap_mp=$(jq -r '.monitorProvider // empty' "${_ap_path}")
    _ap_ma=$(jq -r '.monitorAgent // "goose"' "${_ap_path}")
    _ap_mi=$(jq -r '.maxIterations // 10' "${_ap_path}")
    _ap_ib=$(jq -r '.initialBackoff // 5' "${_ap_path}")
    _ap_td=$(jq -r '.throttleDelay // 0' "${_ap_path}")
    _ap_mr=$(jq -r '.maxRetries // 3' "${_ap_path}")
    _ap_wg=$(jq -r '.workGuidelines // empty' "${_ap_path}")
    _ap_rg=$(jq -r '.reviewGuidelines // empty' "${_ap_path}")

    set_config "${_ap_session}" "${_ap_wm}" "${_ap_wp}" "${_ap_rm}" "${_ap_rp}" "${_ap_mi}" "true" "${_ap_wa}" "${_ap_ra}" "${_ap_wg}" "${_ap_rg}" "${_ap_mm}" "${_ap_mp}" "${_ap_ma}" "${_ap_ib}" "${_ap_td}" "${_ap_mr}"

    echo "[ADAPTIVE] Applied profile: ${_ap_name}" >&2
    return 0
}

test_resource_trigger() {
    _trt_wo="${1:-}"
    _trt_ro="${2:-}"
    _trt_fb="${3:-}"

    if [ -n "${_trt_wo}" ] && is_rate_limit_error "${_trt_wo}"; then
        return 0
    fi
    if [ -n "${_trt_ro}" ] && is_rate_limit_error "${_trt_ro}"; then
        return 0
    fi
    if [ -n "${_trt_fb}" ] && printf '%s\n' "${_trt_fb}" | grep -iqE "(resource|memory|cpu|quota|limit|out of memory)"; then
        return 0
    fi
    return 1
}

test_quality_trigger() {
    for _tqt_text in "${1:-}" "${2:-}" "${3:-}"; do
        if [ -z "${_tqt_text}" ]; then
            continue
        fi
        if printf '%s\n' "${_tqt_text}" | grep -iqE "(low quality|poor quality|nonsensical|incoherent|garbled|repetitive|repeating itself|lorem ipsum|placeholder)"; then
            return 0
        fi
        if printf '%s\n' "${_tqt_text}" | grep -oE '\b\w{8,}\b' | tr '[:upper:]' '[:lower:]' | sort | uniq -c | awk '$1 >= 6 {found=1} END {exit !found}'; then
            return 0
        fi
    done
    return 1
}

get_adaptive_profile_switch() {
    _gaps_strategy="${1}"
    _gaps_trigger="${2}"
    _gaps_current="${3}"

    case "${_gaps_strategy}:${_gaps_trigger}" in
        quality:resource)    _gaps_order="ultra super pro plus lite" ;;
        quality:quality)     _gaps_order="lite plus pro super ultra" ;;
        price:resource)      _gaps_order="ultra super pro plus lite" ;;
        price:quality)       _gaps_order="lite plus pro super ultra" ;;
        balanced:resource)   _gaps_order="pro plus lite" ;;
        balanced:quality)    _gaps_order="pro super ultra" ;;
        *)                   echo ""; return ;;
    esac

    _gaps_first=""
    _gaps_return_next="false"
    for _gaps_item in ${_gaps_order}; do
        if [ -z "${_gaps_first}" ]; then
            _gaps_first="${_gaps_item}"
        fi
        if [ "${_gaps_return_next}" = "true" ]; then
            echo "${_gaps_item}"
            return
        fi
        if [ "${_gaps_item}" = "${_gaps_current}" ]; then
            _gaps_return_next="true"
        fi
    done

    # Wrap around or default to first item
    echo "${_gaps_first}"
}

switch_adaptive_profile() {
    _sap_session="${1}"
    _sap_new="${2}"
    _sap_old="${3:-}"

    echo "[ADAPTIVE] Switching profile from '${_sap_old}' to '${_sap_new}'" >&2
    apply_profile "${_sap_session}" "${_sap_new}"

    _sap_cfg=$(get_config "${_sap_session}")

    _sap_wm=$(printf '%s\n' "${_sap_cfg}" | jq -r '.workerModel // empty')
    _sap_wp=$(printf '%s\n' "${_sap_cfg}" | jq -r '.workerProvider // empty')
    _sap_wa=$(printf '%s\n' "${_sap_cfg}" | jq -r '.workerAgent // "goose"')
    _sap_rm=$(printf '%s\n' "${_sap_cfg}" | jq -r '.reviewerModel // empty')
    _sap_rp=$(printf '%s\n' "${_sap_cfg}" | jq -r '.reviewerProvider // empty')
    _sap_ra=$(printf '%s\n' "${_sap_cfg}" | jq -r '.reviewerAgent // "goose"')
    _sap_mm=$(printf '%s\n' "${_sap_cfg}" | jq -r '.monitorModel // empty')
    _sap_mp=$(printf '%s\n' "${_sap_cfg}" | jq -r '.monitorProvider // empty')
    _sap_ma=$(printf '%s\n' "${_sap_cfg}" | jq -r '.monitorAgent // "goose"')
    _sap_mi=$(printf '%s\n' "${_sap_cfg}" | jq -r '.maxIterations // 10')
    _sap_ib=$(printf '%s\n' "${_sap_cfg}" | jq -r '.initialBackoff // 5')
    _sap_td=$(printf '%s\n' "${_sap_cfg}" | jq -r '.throttleDelay // 0')
    _sap_mr=$(printf '%s\n' "${_sap_cfg}" | jq -r '.maxRetries // 3')

    echo "${_sap_wm}|${_sap_wp}|${_sap_wa}|${_sap_rm}|${_sap_rp}|${_sap_ra}|${_sap_mm}|${_sap_mp}|${_sap_ma}|${_sap_mi}|${_sap_ib}|${_sap_td}|${_sap_mr}"
}

# =============================================================================
# TASK, WORK, REVIEW & STATUS MANAGEMENT
# =============================================================================
set_task() {
    _st_session="${1}"
    _st_task="${2}"
    ensure_state_dir "${_st_session}"
    _st_file="$(get_state_file "${_st_session}" "task.json")"
    jq -n --arg task "${_st_task}" --arg createdAt "$(date -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{task: $task, createdAt: $createdAt}' > "${_st_file}"
    rm -f "$(get_state_file "${_st_session}" "RALPH-BLOCKED.md")"
}

get_task() {
    _gt_file="$(get_state_file "${1:-default}" "task.json")"
    if [ -f "${_gt_file}" ]; then
        cat "${_gt_file}"
    else
        echo ""
    fi
}

set_work() {
    _sw_session="${1}"
    _sw_work="${2}"
    _sw_summary="${3}"
    _sw_iter="${4}"
    ensure_state_dir "${_sw_session}"
    _sw_file="$(get_state_file "${_sw_session}" "work.json")"
    jq -n \
        --arg work "${_sw_work}" \
        --arg summary "${_sw_summary}" \
        --arg submittedAt "$(date -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson iteration "${_sw_iter}" \
        '{work: $work, summary: $summary, submittedAt: $submittedAt, iteration: $iteration}' > "${_sw_file}"
    echo '{"ok":true}' > "$(get_state_file "${_sw_session}" "work-complete.txt")"

    _sw_hist="$(get_state_dir "${_sw_session}")/history/iteration_${_sw_iter}"
    mkdir -p "${_sw_hist}"
    cp "${_sw_file}" "${_sw_hist}/work.json"
    _sw_out="$(get_state_file "${_sw_session}" "work.out")"
    if [ -f "${_sw_out}" ]; then
        cp "${_sw_out}" "${_sw_hist}/work.out"
    fi
}

get_work() {
    _gw_file="$(get_state_file "${1:-default}" "work.json")"
    if [ -f "${_gw_file}" ]; then
        cat "${_gw_file}"
    else
        echo ""
    fi
}

set_review() {
    _sr_session="${1}"
    _sr_decision="${2}"
    _sr_feedback="${3}"
    _sr_iter="${4}"
    ensure_state_dir "${_sr_session}"
    _sr_file="$(get_state_file "${_sr_session}" "review.json")"
    jq -n \
        --arg decision "${_sr_decision}" \
        --arg feedback "${_sr_feedback}" \
        --arg reviewedAt "$(date -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson iteration "${_sr_iter}" \
        '{decision: $decision, feedback: $feedback, reviewedAt: $reviewedAt, iteration: $iteration}' > "${_sr_file}"
    jq -n --arg decision "${_sr_decision}" '{decision: $decision}' > "$(get_state_file "${_sr_session}" "review-result.txt")"
    jq -n --arg feedback "${_sr_feedback}" '{feedback: $feedback}' > "$(get_state_file "${_sr_session}" "review-feedback.txt")"

    _sr_hist="$(get_state_dir "${_sr_session}")/history/iteration_${_sr_iter}"
    mkdir -p "${_sr_hist}"
    cp "${_sr_file}" "${_sr_hist}/review.json"
    _sr_out="$(get_state_file "${_sr_session}" "review.out")"
    if [ -f "${_sr_out}" ]; then
        cp "${_sr_out}" "${_sr_hist}/review.out"
    fi

    if [ "${_sr_decision}" = "REVISE" ]; then
        cleanup_for_next_iteration "${_sr_session}"
    fi
}

get_review() {
    _gr_file="$(get_state_file "${1:-default}" "review.json")"
    if [ -f "${_gr_file}" ]; then
        cat "${_gr_file}"
    else
        echo ""
    fi
}

get_review_result() {
    _grr_file="$(get_state_file "${1:-default}" "review-result.txt")"
    if [ -f "${_grr_file}" ]; then
        jq -r '.decision // empty' "${_grr_file}"
    else
        echo ""
    fi
}

get_feedback() {
    _gf_file="$(get_state_file "${1:-default}" "review-feedback.txt")"
    if [ -f "${_gf_file}" ]; then
        jq -r '.feedback // empty' "${_gf_file}"
    else
        echo ""
    fi
}

get_status() {
    _gs_session="${1:-default}"
    _gs_max_iter="${2:-10}"

    _gs_task=$(get_task "${_gs_session}")
    _gs_work=$(get_work "${_gs_session}")
    _gs_review=$(get_review "${_gs_session}")
    _gs_rev_res=$(get_review_result "${_gs_session}")
    _gs_feedback=$(get_feedback "${_gs_session}")
    _gs_cfg=$(get_config "${_gs_session}")

    _gs_blocked="false"
    if [ -f "$(get_state_file "${_gs_session}" "RALPH-BLOCKED.md")" ]; then
        _gs_blocked="true"
    fi

    _gs_cm_val=$(validate_cross_model "${_gs_session}")

    _gs_phase="WORK"
    _gs_status="running"
    _gs_cur_iter=1

    if [ "${_gs_blocked}" = "true" ]; then
        _gs_phase="BLOCKED"
        _gs_status="blocked"
    elif [ "${_gs_rev_res}" = "SHIP" ]; then
        _gs_phase="COMPLETE"
        _gs_status="shipped"
        if [ -n "${_gs_work}" ]; then
            _gs_cur_iter=$(printf '%s\n' "${_gs_work}" | jq -r '.iteration // 1')
        fi
    elif [ "${_gs_rev_res}" = "REVISE" ]; then
        _gs_phase="WORK"
        _gs_status="revised"
        if [ -n "${_gs_work}" ]; then
            _gs_cur_iter=$(($(printf '%s\n' "${_gs_work}" | jq -r '.iteration // 1') + 1))
        fi
    elif [ -n "${_gs_work}" ]; then
        _gs_phase="REVIEW"
        _gs_status="running"
        _gs_cur_iter=$(printf '%s\n' "${_gs_work}" | jq -r '.iteration // 1')
    fi

    if [ "${_gs_cur_iter}" -gt "${_gs_max_iter}" ] && [ "${_gs_status}" = "running" ]; then
        _gs_status="max_iterations_reached"
        _gs_phase="COMPLETE"
    fi

    _gs_task_text=""
    _gs_created_at=""
    if [ -n "${_gs_task}" ]; then
        _gs_task_text=$(printf '%s\n' "${_gs_task}" | jq -r '.task // empty')
        _gs_created_at=$(printf '%s\n' "${_gs_task}" | jq -r '.createdAt // empty')
    fi

    _gs_work_sum=""
    if [ -n "${_gs_work}" ]; then
        _gs_work_sum=$(printf '%s\n' "${_gs_work}" | jq -r '.summary // empty')
    fi

    _gs_wm=""
    _gs_wp=""
    _gs_wa=""
    _gs_rm=""
    _gs_rp=""
    _gs_ra=""
    _gs_mm=""
    _gs_mp=""
    _gs_ma=""
    _gs_cm_enforced="true"
    _gs_cm_valid="true"
    _gs_cm_warn=""
    _gs_wg=""
    _gs_rg=""
    if [ -n "${_gs_cfg}" ]; then
        _gs_wm=$(printf '%s\n' "${_gs_cfg}" | jq -r '.workerModel // empty')
        _gs_wp=$(printf '%s\n' "${_gs_cfg}" | jq -r '.workerProvider // empty')
        _gs_wa=$(printf '%s\n' "${_gs_cfg}" | jq -r '.workerAgent // empty')
        _gs_rm=$(printf '%s\n' "${_gs_cfg}" | jq -r '.reviewerModel // empty')
        _gs_rp=$(printf '%s\n' "${_gs_cfg}" | jq -r '.reviewerProvider // empty')
        _gs_ra=$(printf '%s\n' "${_gs_cfg}" | jq -r '.reviewerAgent // empty')
        _gs_mm=$(printf '%s\n' "${_gs_cfg}" | jq -r '.monitorModel // empty')
        _gs_mp=$(printf '%s\n' "${_gs_cfg}" | jq -r '.monitorProvider // empty')
        _gs_ma=$(printf '%s\n' "${_gs_cfg}" | jq -r '.monitorAgent // empty')
        _gs_cm_enforced=$(printf '%s\n' "${_gs_cfg}" | jq -r '.crossModelReviewEnforced // true')
        _gs_cm_valid=$(printf '%s\n' "${_gs_cm_val}" | jq -r '.valid // true')
        _gs_cm_warn=$(printf '%s\n' "${_gs_cm_val}" | jq -r '.warning // empty')
        _gs_wg=$(printf '%s\n' "${_gs_cfg}" | jq -r '.workGuidelines // empty')
        _gs_rg=$(printf '%s\n' "${_gs_cfg}" | jq -r '.reviewGuidelines // empty')
    fi

    jq -n \
        --arg sessionId "${_gs_session}" \
        --argjson currentIteration "${_gs_cur_iter}" \
        --argjson maxIterations "${_gs_max_iter}" \
        --arg phase "${_gs_phase}" \
        --arg status "${_gs_status}" \
        --arg task "${_gs_task_text}" \
        --arg lastWorkSummary "${_gs_work_sum}" \
        --arg lastFeedback "${_gs_feedback}" \
        --arg createdAt "${_gs_created_at}" \
        --arg updatedAt "$(date -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg workerModel "${_gs_wm}" \
        --arg workerProvider "${_gs_wp}" \
        --arg workerAgent "${_gs_wa}" \
        --arg reviewerModel "${_gs_rm}" \
        --arg reviewerProvider "${_gs_rp}" \
        --arg reviewerAgent "${_gs_ra}" \
        --arg monitorModel "${_gs_mm}" \
        --arg monitorProvider "${_gs_mp}" \
        --arg monitorAgent "${_gs_ma}" \
        --argjson crossModelEnforced "${_gs_cm_enforced}" \
        --argjson crossModelValid "${_gs_cm_valid}" \
        --arg crossModelWarning "${_gs_cm_warn}" \
        --arg workGuidelines "${_gs_wg}" \
        --arg reviewGuidelines "${_gs_rg}" \
        '{
            sessionId: $sessionId,
            currentIteration: $currentIteration,
            maxIterations: $maxIterations,
            phase: $phase,
            status: $status,
            task: (if $task == "" then null else $task end),
            lastWorkSummary: (if $lastWorkSummary == "" then null else $lastWorkSummary end),
            lastFeedback: (if $lastFeedback == "" then null else $lastFeedback end),
            createdAt: (if $createdAt == "" then null else $createdAt end),
            updatedAt: $updatedAt,
            workerModel: (if $workerModel == "" then null else $workerModel end),
            workerProvider: (if $workerProvider == "" then null else $workerProvider end),
            workerAgent: (if $workerAgent == "" then null else $workerAgent end),
            reviewerModel: (if $reviewerModel == "" then null else $reviewerModel end),
            reviewerProvider: (if $reviewerProvider == "" then null else $reviewerProvider end),
            reviewerAgent: (if $reviewerAgent == "" then null else $reviewerAgent end),
            monitorModel: (if $monitorModel == "" then null else $monitorModel end),
            monitorProvider: (if $monitorProvider == "" then null else $monitorProvider end),
            monitorAgent: (if $monitorAgent == "" then null else $monitorAgent end),
            crossModelReviewEnforced: $crossModelEnforced,
            crossModelReviewValid: $crossModelValid,
            crossModelReviewWarning: (if $crossModelWarning == "" then null else $crossModelWarning end),
            workGuidelines: (if $workGuidelines == "" then null else $workGuidelines end),
            reviewGuidelines: (if $reviewGuidelines == "" then null else $reviewGuidelines end)
        }'
}

cleanup_for_next_iteration() {
    _cfni_session="${1}"
    rm -f "$(get_state_file "${_cfni_session}" "work-complete.txt")"
    rm -f "$(get_state_file "${_cfni_session}" "review-result.txt")"
    rm -f "$(get_state_file "${_cfni_session}" "review-feedback.txt")"
    rm -f "$(get_state_file "${_cfni_session}" "work.json")"
    rm -f "$(get_state_file "${_cfni_session}" "review.json")"
    rm -f "$(get_state_file "${_cfni_session}" "work.out")"
    rm -f "$(get_state_file "${_cfni_session}" "review.out")"
}

reset_session() {
    _rs_dir=$(get_state_dir "${1}")
    if [ -d "${_rs_dir}" ]; then
        rm -rf "${_rs_dir}"
    fi
}

block_iteration() {
    ensure_state_dir "${1}"
    echo "${2}" > "$(get_state_file "${1}" "RALPH-BLOCKED.md")"
}

# =============================================================================
# ORCHESTRATION FUNCTIONS (CLI mode & Monitoring Agent)
# =============================================================================
call_llm_worker() {
    _clw_task="$1"
    _clw_feedback="$2"
    _clw_iter="$3"
    _clw_session="$4"
    _clw_wm="$5"
    _clw_wp="$6"
    _clw_wa="$7"
    _clw_wg="$8"
    _clw_existing="${9:-false}"

    _clw_prompt="You are the WORKER in a Ralph Loop iteration ${_clw_iter}.

Task: ${_clw_task}"

    if [ -n "${_clw_feedback}" ]; then
        _clw_prompt="${_clw_prompt}

Previous feedback from reviewer: ${_clw_feedback}

Please revise your work based on this feedback."
    fi

    _clw_prompt="${_clw_prompt}

Provide your complete work output and a brief summary.
Output format:
WORK:
[your complete work here]

SUMMARY:
[brief summary of what you did]"

    case "${_clw_wa}" in
        anthropic|claude)
            execute_llm_with_retry "WORKER" "${_clw_session}" sh -c "echo $(json_escape "${_clw_prompt}") | claude --model ${_clw_wm} --print"
            ;;
        openai)
            execute_llm_with_retry "WORKER" "${_clw_session}" sh -c "echo $(json_escape "${_clw_prompt}") | openai chat --model ${_clw_wm} --no-stream"
            ;;
        google|gemini)
            execute_llm_with_retry "WORKER" "${_clw_session}" sh -c "echo $(json_escape "${_clw_prompt}") | gemini --model ${_clw_wm} --format=text"
            ;;
        copilot)
            execute_llm_with_retry "WORKER" "${_clw_session}" copilot -p --allow-all-tools "${_clw_prompt}"
            ;;
        goose)
            _clw_params="task=${_clw_task} sessionId=${_clw_session}"
            if [ -n "${_clw_feedback}" ]; then
                _clw_params="${_clw_params} feedback=${_clw_feedback}"
            fi
            set -- run
            if [ -n "${_clw_wg}" ] && [ -f "${_clw_wg}" ]; then
                set -- "$@" --recipe "${_clw_wg}"
            fi
            set -- "$@" --params "${_clw_params}"
            if [ -n "${_clw_session}" ]; then
                if [ "${_clw_existing}" = "true" ]; then
                    set -- "$@" --resume
                fi
                set -- "$@" --name "${_clw_session}"
            else
                set -- "$@" --no-session
            fi
            set -- "$@" --text "${_clw_prompt}"

            execute_llm_with_retry "WORKER" "${_clw_session}" env GOOSE_MODEL="${_clw_wm}" GOOSE_PROVIDER="${_clw_wp}" goose "$@"
            ;;
        *)
            echo "Error: Unknown agent ${_clw_wa}" >&2
            return 1
            ;;
    esac
}

call_llm_reviewer() {
    _clr_task="$1"
    _clr_work="$2"
    _clr_summary="$3"
    _clr_iter="$4"
    _clr_session="$5"
    _clr_rm="$6"
    _clr_rp="$7"
    _clr_ra="$8"
    _clr_rg="$9"
    _clr_existing="${10:-false}"

    _clr_prompt="You are the REVIEWER in a Ralph Loop iteration ${_clr_iter}.

Original Task: ${_clr_task}

Worker's Work:
${_clr_work}

Worker's Summary: ${_clr_summary}

Review this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).
If REVISE, provide specific, actionable feedback for the worker.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [your feedback, or empty if SHIP]"

    case "${_clr_ra}" in
        anthropic|claude)
            execute_llm_with_retry "REVIEWER" "${_clr_session}" sh -c "echo $(json_escape "${_clr_prompt}") | claude --model ${_clr_rm} --print"
            ;;
        openai)
            execute_llm_with_retry "REVIEWER" "${_clr_session}" sh -c "echo $(json_escape "${_clr_prompt}") | openai chat --model ${_clr_rm} --no-stream"
            ;;
        google|gemini)
            execute_llm_with_retry "REVIEWER" "${_clr_session}" sh -c "echo $(json_escape "${_clr_prompt}") | gemini --model ${_clr_rm} --format=text"
            ;;
        copilot)
            execute_llm_with_retry "REVIEWER" "${_clr_session}" copilot -p --allow-all-tools "${_clr_prompt}"
            ;;
        goose)
            set -- run
            if [ -n "${_clr_rg}" ] && [ -f "${_clr_rg}" ]; then
                set -- "$@" --recipe "${_clr_rg}"
            fi
            set -- "$@" --params "task=${_clr_task} work=${_clr_work} summary=${_clr_summary} sessionId=${_clr_session}"
            if [ -n "${_clr_session}" ]; then
                if [ "${_clr_existing}" = "true" ]; then
                    set -- "$@" --resume
                fi
                set -- "$@" --name "${_clr_session}"
            else
                set -- "$@" --no-session
            fi
            set -- "$@" --text "${_clr_prompt}"

            execute_llm_with_retry "REVIEWER" "${_clr_session}" env GOOSE_MODEL="${_clr_rm}" GOOSE_PROVIDER="${_clr_rp}" goose "$@"
            ;;
        *)
            echo "Error: Unknown agent ${_clr_ra}" >&2
            return 1
            ;;
    esac
}

call_llm_monitor() {
    _clm_prompt="$1"
    _clm_session="${2:-}"
    _clm_mm="${3:-${MONITOR_MODEL}}"
    _clm_mp="${4:-${MONITOR_PROVIDER}}"
    _clm_ma="${5:-${MONITOR_AGENT}}"

    if [ -z "${_clm_mm}" ]; then _clm_mm="${WORKER_MODEL}"; fi
    if [ -z "${_clm_mp}" ]; then _clm_mp="${WORKER_PROVIDER}"; fi
    if [ -z "${_clm_ma}" ]; then _clm_ma="${WORKER_AGENT}"; fi

    case "${_clm_ma}" in
        anthropic|claude)
            execute_llm_with_retry "MONITOR" "${_clm_session}" sh -c "echo $(json_escape "${_clm_prompt}") | claude --model ${_clm_mm} --print"
            ;;
        openai)
            execute_llm_with_retry "MONITOR" "${_clm_session}" sh -c "echo $(json_escape "${_clm_prompt}") | openai chat --model ${_clm_mm} --no-stream"
            ;;
        google|gemini)
            execute_llm_with_retry "MONITOR" "${_clm_session}" sh -c "echo $(json_escape "${_clm_prompt}") | gemini --model ${_clm_mm} --format=text"
            ;;
        goose)
            execute_llm_with_retry "MONITOR" "${_clm_session}" env GOOSE_MODEL="${_clm_mm}" GOOSE_PROVIDER="${_clm_mp}" goose run --no-session --text "${_clm_prompt}"
            ;;
        *)
            execute_llm_with_retry "MONITOR" "${_clm_session}" sh -c "echo $(json_escape "${_clm_prompt}") | openai chat --model ${_clm_mm} --no-stream"
            ;;
    esac
}

parse_worker_output() {
    _pwo_output="$1"
    _pwo_session="${2:-}"
    _pwo_mm="${3:-}"
    _pwo_mp="${4:-}"
    _pwo_ma="${5:-}"
    _pwo_file="${6:-}"

    _pwo_work=""
    _pwo_summary=""

    if [ "${_pwo_output#*WORK:}" != "${_pwo_output}" ]; then
        _pwo_work=$(printf '%s\n' "${_pwo_output}" | awk '/^WORK:/{flag=1; next} /^SUMMARY:/{flag=0} flag')
    fi
    if [ "${_pwo_output#*SUMMARY:}" != "${_pwo_output}" ]; then
        _pwo_summary=$(printf '%s\n' "${_pwo_output}" | awk '/^SUMMARY:/{flag=1; next} flag')
    fi

    if [ -z "${_pwo_work}" ] || [ -z "${_pwo_summary}" ]; then
        echo "  Regex parsing failed for worker output, consulting Monitor LLM..." >&2
        if [ "${_pwo_ma}" = "goose" ] && [ -n "${_pwo_file}" ] && [ -f "${_pwo_file}" ]; then
            _pwo_mprompt="Read the file at '${_pwo_file}' then extract the WORK and SUMMARY sections from its content.

If the agent created or modified files, include the file paths and key content in WORK.
Summarize what was accomplished in SUMMARY.

Output format:
WORK:
[extracted work content]

SUMMARY:
[one-line summary]"
        else
            _pwo_mprompt="Extract the WORK and SUMMARY sections from the following raw agent output.

If the agent created or modified files, include the file paths and key content in WORK.
Summarize what was accomplished in SUMMARY.

Output format:
WORK:
[extracted work content]

SUMMARY:
[one-line summary]

---
${_pwo_output}"
        fi

        _pwo_mresp=$(call_llm_monitor "${_pwo_mprompt}" "${_pwo_session}" "${_pwo_mm}" "${_pwo_mp}" "${_pwo_ma}" || true)
        if [ -n "${_pwo_mresp}" ]; then
            if [ "${_pwo_mresp#*WORK:}" != "${_pwo_mresp}" ]; then
                _pwo_work=$(printf '%s\n' "${_pwo_mresp}" | awk '/^WORK:/{flag=1; next} /^SUMMARY:/{flag=0} flag')
            fi
            if [ "${_pwo_mresp#*SUMMARY:}" != "${_pwo_mresp}" ]; then
                _pwo_summary=$(printf '%s\n' "${_pwo_mresp}" | awk '/^SUMMARY:/{flag=1; next} flag')
            fi
        fi

        if [ -n "${_pwo_work}" ] || [ -n "${_pwo_summary}" ]; then
            echo "  Monitor LLM parsed successfully." >&2
        else
            echo "  Monitor LLM also could not parse the output." >&2
        fi
    fi

    echo "${_pwo_work}|${_pwo_summary}"
}

parse_reviewer_output() {
    _pro_output="$1"
    _pro_session="${2:-}"
    _pro_mm="${3:-}"
    _pro_mp="${4:-}"
    _pro_ma="${5:-}"
    _pro_file="${6:-}"

    _pro_decision=""
    _pro_feedback=""

    if [ "${_pro_output#*DECISION:}" != "${_pro_output}" ]; then
        _pro_decision=$(printf '%s\n' "${_pro_output}" | awk '/^DECISION:/{print toupper($2); exit}')
    fi
    if [ "${_pro_output#*FEEDBACK:}" != "${_pro_output}" ]; then
        _pro_feedback=$(printf '%s\n' "${_pro_output}" | awk '/^FEEDBACK:/{flag=1; next} flag')
    fi

    if [ "${_pro_decision}" != "SHIP" ] && [ "${_pro_decision}" != "REVISE" ]; then
        echo "  Regex parsing failed for reviewer output, consulting Monitor LLM..." >&2
        if [ "${_pro_ma}" = "goose" ] && [ -n "${_pro_file}" ] && [ -f "${_pro_file}" ]; then
            _pro_mprompt="Read the file at '${_pro_file}' then extract the DECISION (SHIP or REVISE) and FEEDBACK from its content.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [the review feedback]"
        else
            _pro_mprompt="Extract the DECISION (SHIP or REVISE) and FEEDBACK from the following raw agent output.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [the review feedback]

---
${_pro_output}"
        fi

        _pro_mresp=$(call_llm_monitor "${_pro_mprompt}" "${_pro_session}" "${_pro_mm}" "${_pro_mp}" "${_pro_ma}" || true)
        if [ -n "${_pro_mresp}" ]; then
            if [ "${_pro_mresp#*DECISION:}" != "${_pro_mresp}" ]; then
                _pro_decision=$(printf '%s\n' "${_pro_mresp}" | awk '/^DECISION:/{print toupper($2); exit}')
            fi
            if [ "${_pro_mresp#*FEEDBACK:}" != "${_pro_mresp}" ]; then
                _pro_feedback=$(printf '%s\n' "${_pro_mresp}" | awk '/^FEEDBACK:/{flag=1; next} flag')
            fi
        fi

        if [ "${_pro_decision}" = "SHIP" ] || [ "${_pro_decision}" = "REVISE" ]; then
            echo "  Monitor LLM parsed successfully." >&2
        else
            echo "  Monitor LLM also could not parse the output." >&2
        fi
    fi

    echo "${_pro_decision}|${_pro_feedback}"
}

# =============================================================================
# CLI ORCHESTRATION MODE
# =============================================================================
run_cli() {
    _rc_adaptive="false"
    _rc_strategy="balanced"
    _rc_cur_prof="${RALPH_PROFILE:-}"
    _rc_cli_prof=""
    _rc_wm="${WORKER_MODEL}"
    _rc_wp="${WORKER_PROVIDER}"
    _rc_wa="${WORKER_AGENT}"
    _rc_rm="${REVIEWER_MODEL}"
    _rc_rp="${REVIEWER_PROVIDER}"
    _rc_ra="${REVIEWER_AGENT}"
    _rc_max_iter="${MAX_ITERATIONS}"
    _rc_wg="${WORK_GUIDELINES}"
    _rc_rg="${REVIEW_GUIDELINES}"
    _rc_mm="${MONITOR_MODEL}"
    _rc_mp="${MONITOR_PROVIDER}"
    _rc_ma="${MONITOR_AGENT}"
    _rc_retries="${RALPH_MAX_RETRIES}"
    _rc_backoff="${RALPH_INITIAL_BACKOFF}"
    _rc_throttle="${RALPH_THROTTLE_DELAY}"
    _rc_task_in=""
    _rc_workspace="${WORKSPACE}"

    while [ $# -gt 0 ]; do
        case "${1}" in
            -h|--help)
                echo "Usage: $0 [options] \"task description\" or $0 [options] /path/to/task.md"
                echo ""
                echo "Modes:"
                echo "  MCP Server  : $0 [--stdio | --http | --streamable-http] [--port PORT]"
                echo "  CLI Mode    : $0 [options] \"task description\" [--profile pro]"
                echo ""
                echo "Options:"
                echo "  --profile PROFILE            Quality profile (lite, plus, pro, super, ultra)"
                echo "  --worker-model MODEL         Worker model (default: \$RALPH_WORKER_MODEL)"
                echo "  --worker-provider PROVIDER   Worker provider (default: \$RALPH_WORKER_PROVIDER)"
                echo "  --worker-agent AGENT         Worker agent (default: \$RALPH_WORKER_AGENT)"
                echo "  --reviewer-model MODEL       Reviewer model (default: \$RALPH_REVIEWER_MODEL)"
                echo "  --reviewer-provider PROVIDER Reviewer provider (default: \$RALPH_REVIEWER_PROVIDER)"
                echo "  --reviewer-agent AGENT       Reviewer agent (default: \$RALPH_REVIEWER_AGENT)"
                echo "  --monitor-model MODEL        Monitor model (default: \$RALPH_MONITOR_MODEL)"
                echo "  --monitor-provider PROVIDER  Monitor provider (default: \$RALPH_MONITOR_PROVIDER)"
                echo "  --monitor-agent AGENT        Monitor agent (default: \$RALPH_MONITOR_AGENT)"
                echo "  --max-iterations N           Max iterations, -1 for infinite (default: \$RALPH_MAX_ITERATIONS)"
                echo "  --work-guidelines FILE       Work guidelines/recipe file (default: \$RALPH_WORK_GUIDELINES)"
                echo "  --review-guidelines FILE     Review guidelines/recipe file (default: \$RALPH_REVIEW_GUIDELINES)"
                echo "  --session-id ID              Session ID (default: auto-generated)"
                echo "  --max-retries N              Max retry attempts for rate limits (default: \$RALPH_MAX_RETRIES)"
                echo "  --initial-backoff N          Initial backoff seconds for retries (default: \$RALPH_INITIAL_BACKOFF)"
                echo "  --throttle-delay N           Delay between requests in seconds (default: \$RALPH_THROTTLE_DELAY)"
                echo "  --enable-adaptive            Enable adaptive profile switching"
                echo "  --adaptive-strategy STRATEGY Adaptive strategy: quality, price, or balanced (default: balanced)"
                echo "  --workspace DIR              Workspace directory (default: current working directory)"
                exit 0
                ;;
            --profile)
                _rc_cli_prof="${2:-}"
                shift 2
                ;;
            --worker-model)
                _rc_wm="${2:-}"
                shift 2
                ;;
            --worker-provider)
                _rc_wp="${2:-}"
                shift 2
                ;;
            --worker-agent)
                _rc_wa="${2:-}"
                shift 2
                ;;
            --reviewer-model)
                _rc_rm="${2:-}"
                shift 2
                ;;
            --reviewer-provider)
                _rc_rp="${2:-}"
                shift 2
                ;;
            --reviewer-agent)
                _rc_ra="${2:-}"
                shift 2
                ;;
            --monitor-model)
                _rc_mm="${2:-}"
                shift 2
                ;;
            --monitor-provider)
                _rc_mp="${2:-}"
                shift 2
                ;;
            --monitor-agent)
                _rc_ma="${2:-}"
                shift 2
                ;;
            --max-iterations)
                _rc_max_iter="${2:-${MAX_ITERATIONS}}"
                shift 2
                ;;
            --work-guidelines)
                _rc_wg="${2:-}"
                shift 2
                ;;
            --review-guidelines)
                _rc_rg="${2:-}"
                shift 2
                ;;
            --max-retries)
                _rc_retries="${2:-${RALPH_MAX_RETRIES}}"
                shift 2
                ;;
            --initial-backoff)
                _rc_backoff="${2:-${RALPH_INITIAL_BACKOFF}}"
                shift 2
                ;;
            --throttle-delay)
                _rc_throttle="${2:-${RALPH_THROTTLE_DELAY}}"
                shift 2
                ;;
            --enable-adaptive)
                _rc_adaptive="true"
                shift
                ;;
            --adaptive-strategy)
                _rc_strategy="${2:-balanced}"
                shift 2
                ;;
            --workspace)
                _rc_workspace="${2:-}"
                shift 2
                ;;
            --session-id)
                CLI_SESSION_ID="${2:-}"
                shift 2
                ;;
            -*)
                echo "Error: Unknown option: ${1}" >&2
                exit 1
                ;;
            *)
                _rc_task_in="${1}"
                shift
                ;;
        esac
    done

    RALPH_MAX_RETRIES="${_rc_retries}"
    RALPH_INITIAL_BACKOFF="${_rc_backoff}"
    RALPH_THROTTLE_DELAY="${_rc_throttle}"

    if [ -n "${_rc_workspace}" ]; then
        WORKSPACE="$(cd "${_rc_workspace}" 2>/dev/null && pwd || echo "${_rc_workspace}")"
        RALPH_STATE_BASE="${WORKSPACE}/.ralph"
    fi

    if [ -n "${_rc_cli_prof}" ]; then
        if _rc_prof_path="$(resolve_profile_path "${_rc_cli_prof}")"; then
            [ -z "${_rc_wm}" ] && _rc_wm=$(jq -r '.workerModel // empty' "${_rc_prof_path}")
            [ -z "${_rc_wp}" ] && _rc_wp=$(jq -r '.workerProvider // empty' "${_rc_prof_path}")
            _rc_wa=$(jq -r '.workerAgent // "goose"' "${_rc_prof_path}")
            [ -z "${_rc_rm}" ] && _rc_rm=$(jq -r '.reviewerModel // empty' "${_rc_prof_path}")
            [ -z "${_rc_rp}" ] && _rc_rp=$(jq -r '.reviewerProvider // empty' "${_rc_prof_path}")
            _rc_ra=$(jq -r '.reviewerAgent // "goose"' "${_rc_prof_path}")
            [ -z "${_rc_mm}" ] && _rc_mm=$(jq -r '.monitorModel // empty' "${_rc_prof_path}")
            [ -z "${_rc_mp}" ] && _rc_mp=$(jq -r '.monitorProvider // empty' "${_rc_prof_path}")
            _rc_ma=$(jq -r '.monitorAgent // "goose"' "${_rc_prof_path}")
            _rc_max_iter=$(jq -r '.maxIterations // 10' "${_rc_prof_path}")
            _rc_backoff=$(jq -r '.initialBackoff // 5' "${_rc_prof_path}")
            _rc_throttle=$(jq -r '.throttleDelay // 0' "${_rc_prof_path}")
            _rc_retries=$(jq -r '.maxRetries // 3' "${_rc_prof_path}")
            _rc_cur_prof="${_rc_cli_prof}"
        else
            echo "[ERROR] Profile not found: ${_rc_cli_prof}" >&2
            exit 1
        fi
    fi

    _rc_task=""
    _rc_task_file=""
    if [ -n "${_rc_task_in}" ]; then
        if [ -f "${_rc_task_in}" ]; then
            _rc_task_file="${_rc_task_in}"
        elif [ -f "${WORKSPACE}/${_rc_task_in}" ]; then
            _rc_task_file="${WORKSPACE}/${_rc_task_in}"
        fi
    fi
    if [ -n "${_rc_task_file}" ]; then
        _rc_task=$(cat "${_rc_task_file}")
    else
        _rc_task="${_rc_task_in}"
    fi

    if [ -z "${_rc_task}" ]; then
        echo "Error: No task provided" >&2
        exit 1
    fi

    if [ -z "${_rc_wm}" ] || [ -z "${_rc_wp}" ] || [ -z "${_rc_rm}" ] || [ -z "${_rc_rp}" ]; then
        if [ ! -t 0 ]; then
            echo "[ERROR] Missing required worker/reviewer model or provider in non-interactive mode. Use --profile <lite|plus|pro|super|ultra> or pass --worker-model, --worker-provider, --reviewer-model, --reviewer-provider." >&2
            exit 1
        fi
    fi

    if [ -z "${_rc_wm}" ]; then
        printf 'Worker model: '
        read -r _rc_wm || exit 1
        [ -z "${_rc_wm}" ] && exit 1
    fi
    if [ -z "${_rc_wp}" ]; then
        printf 'Worker provider (anthropic/openai/google/goose/copilot): '
        read -r _rc_wp || exit 1
        [ -z "${_rc_wp}" ] && exit 1
    fi
    if [ -z "${_rc_wa}" ]; then
        printf 'Worker agent (goose/claude/openai/gemini/copilot): '
        read -r _rc_wa || exit 1
        [ -z "${_rc_wa}" ] && exit 1
    fi
    if [ -z "${_rc_rm}" ]; then
        printf 'Reviewer model (should be different from worker): '
        read -r _rc_rm || exit 1
        [ -z "${_rc_rm}" ] && exit 1
    fi
    if [ -z "${_rc_rp}" ]; then
        printf 'Reviewer provider (anthropic/openai/google/goose/copilot): '
        read -r _rc_rp || exit 1
        [ -z "${_rc_rp}" ] && exit 1
    fi
    if [ -z "${_rc_ra}" ]; then
        printf 'Reviewer agent (goose/claude/openai/gemini/copilot): '
        read -r _rc_ra || exit 1
        [ -z "${_rc_ra}" ] && exit 1
    fi

    if [ "${_rc_wm}" = "${_rc_rm}" ] && [ "${_rc_wp}" = "${_rc_rp}" ]; then
        if [ ! -t 0 ]; then
            echo "[ERROR] Worker and reviewer cannot be the same model/provider in non-interactive mode." >&2
            exit 1
        fi
        echo "Warning: Worker and reviewer are the same model/provider."
        printf 'Continue? [y/N]: '
        read -r _rc_confirm || exit 1
        if [ "${_rc_confirm}" != "y" ] && [ "${_rc_confirm}" != "Y" ]; then exit 1; fi
    fi

    _rc_session="${CLI_SESSION_ID:-ralph-$(date +%s)}"
    echo "Session: ${_rc_session}"
    echo "Task: ${_rc_task}"
    echo "Worker: ${_rc_wm} (${_rc_wp}) via ${_rc_wa}"
    echo "Reviewer: ${_rc_rm} (${_rc_rp}) via ${_rc_ra}"
    if [ -n "${_rc_mm}" ]; then
        echo "Monitor: ${_rc_mm} (${_rc_mp}) via ${_rc_ma}"
    fi
    if [ "${_rc_max_iter}" -eq -1 ]; then
        echo "Max Iterations: unlimited"
    else
        echo "Max Iterations: ${_rc_max_iter}"
    fi
    echo ""

    set_task "${_rc_session}" "${_rc_task}"
    set_config "${_rc_session}" "${_rc_wm}" "${_rc_wp}" "${_rc_rm}" "${_rc_rp}" "${_rc_max_iter}" "true" "${_rc_wa}" "${_rc_ra}" "${_rc_wg}" "${_rc_rg}" "${_rc_mm}" "${_rc_mp}" "${_rc_ma}" "${_rc_backoff}" "${_rc_throttle}" "${_rc_retries}"

    if [ "${_rc_adaptive}" = "true" ]; then
        case "${_rc_strategy}" in
            quality|price|balanced) ;;
            *) echo "[WARNING] Unknown adaptive strategy '${_rc_strategy}'; falling back to 'balanced'." >&2; _rc_strategy="balanced" ;;
        esac
        if [ -z "${_rc_cur_prof}" ]; then
            case "${_rc_strategy}" in
                quality) _rc_cur_prof="ultra" ;;
                price)   _rc_cur_prof="lite" ;;
                *)       _rc_cur_prof="pro" ;;
            esac
            echo "[ADAPTIVE] Strategy '${_rc_strategy}' (start profile '${_rc_cur_prof}')" >&2
        else
            echo "[ADAPTIVE] Strategy '${_rc_strategy}' (starting from '${_rc_cur_prof}')" >&2
        fi
    fi

    _rc_feedback=""
    _rc_iter=1
    if [ "${_rc_max_iter}" -eq -1 ]; then
        _rc_limit=999999999
    else
        _rc_limit="${_rc_max_iter}"
    fi

    while [ "${_rc_iter}" -le "${_rc_limit}" ]; do
        echo "======================================================================"
        echo "  Iteration ${_rc_iter} / ${_rc_max_iter}"
        echo "======================================================================"

        echo "[WORK] WORK PHASE"
        echo "Worker: ${_rc_wm} (${_rc_wp}) via ${_rc_wa}"

        _rc_existing="false"
        if [ -n "${CLI_SESSION_ID}" ] || [ "${_rc_iter}" -gt 1 ]; then
            _rc_existing="true"
        fi

        _rc_w_out=$(call_llm_worker "${_rc_task}" "${_rc_feedback}" "${_rc_iter}" "${_rc_session}" "${_rc_wm}" "${_rc_wp}" "${_rc_wa}" "${_rc_wg}" "${_rc_existing}" || true)

        case "${_rc_w_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                if [ "${_rc_adaptive}" = "true" ]; then
                    _rc_new_prof=$(get_adaptive_profile_switch "${_rc_strategy}" "resource" "${_rc_cur_prof}")
                    if [ -n "${_rc_new_prof}" ] && [ "${_rc_new_prof}" != "${_rc_cur_prof}" ]; then
                        _rc_sw=$(switch_adaptive_profile "${_rc_session}" "${_rc_new_prof}" "${_rc_cur_prof}")
                        _rc_cur_prof="${_rc_new_prof}"
                        IFS='|' read -r _rc_wm _rc_wp _rc_wa _rc_rm _rc_rp _rc_ra _rc_mm _rc_mp _rc_ma _rc_max_iter _rc_backoff _rc_throttle _rc_retries <<EOF
${_rc_sw}
EOF
                        echo "[ADAPTIVE] Retrying work phase with upgraded profile '${_rc_cur_prof}'" >&2
                        _rc_w_out=$(call_llm_worker "${_rc_task}" "${_rc_feedback}" "${_rc_iter}" "${_rc_session}" "${_rc_wm}" "${_rc_wp}" "${_rc_wa}" "${_rc_wg}" "${_rc_existing}" || true)
                    fi
                fi
                ;;
        esac

        case "${_rc_w_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                echo "[WARN] WORK PHASE FAILED - Rate limit, quota error, or no output from worker" >&2
                block_iteration "${_rc_session}" "WORK PHASE FAILED - Rate limit or quota error from worker LLM"
                exit 1
                ;;
        esac

        _rc_w_file="$(get_state_file "${_rc_session}" "work.out")"
        printf '%s\n' "${_rc_w_out}" > "${_rc_w_file}"

        _rc_parsed=$(parse_worker_output "${_rc_w_out}" "${_rc_session}" "${_rc_mm}" "${_rc_mp}" "${_rc_ma}" "${_rc_w_file}")
        _rc_work=$(printf '%s\n' "${_rc_parsed}" | cut -d'|' -f1)
        _rc_summary=$(printf '%s\n' "${_rc_parsed}" | cut -d'|' -f2)

        if [ -z "${_rc_work}" ] || [ -z "${_rc_summary}" ]; then
            echo "[WARN] WORK PHASE FAILED - Could not parse output" >&2
            exit 1
        fi

        set_work "${_rc_session}" "${_rc_work}" "${_rc_summary}" "${_rc_iter}"
        echo "Work submitted. Summary: ${_rc_summary}"
        echo ""

        echo "[REVIEW] REVIEW PHASE"
        echo "Reviewer: ${_rc_rm} (${_rc_rp}) via ${_rc_ra}"

        _rc_r_out=$(call_llm_reviewer "${_rc_task}" "${_rc_work}" "${_rc_summary}" "${_rc_iter}" "${_rc_session}" "${_rc_rm}" "${_rc_rp}" "${_rc_ra}" "${_rc_rg}" "${_rc_existing}" || true)

        case "${_rc_r_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                if [ "${_rc_adaptive}" = "true" ]; then
                    _rc_new_prof=$(get_adaptive_profile_switch "${_rc_strategy}" "resource" "${_rc_cur_prof}")
                    if [ -n "${_rc_new_prof}" ] && [ "${_rc_new_prof}" != "${_rc_cur_prof}" ]; then
                        _rc_sw=$(switch_adaptive_profile "${_rc_session}" "${_rc_new_prof}" "${_rc_cur_prof}")
                        _rc_cur_prof="${_rc_new_prof}"
                        IFS='|' read -r _rc_wm _rc_wp _rc_wa _rc_rm _rc_rp _rc_ra _rc_mm _rc_mp _rc_ma _rc_max_iter _rc_backoff _rc_throttle _rc_retries <<EOF
${_rc_sw}
EOF
                        echo "[ADAPTIVE] Retrying review phase with upgraded profile '${_rc_cur_prof}'" >&2
                        _rc_r_out=$(call_llm_reviewer "${_rc_task}" "${_rc_work}" "${_rc_summary}" "${_rc_iter}" "${_rc_session}" "${_rc_rm}" "${_rc_rp}" "${_rc_ra}" "${_rc_rg}" "${_rc_existing}" || true)
                    fi
                fi
                ;;
        esac

        case "${_rc_r_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                echo "[WARN] REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer" >&2
                block_iteration "${_rc_session}" "REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM"
                exit 1
                ;;
        esac

        _rc_r_file="$(get_state_file "${_rc_session}" "review.out")"
        printf '%s\n' "${_rc_r_out}" > "${_rc_r_file}"

        _rc_parsed=$(parse_reviewer_output "${_rc_r_out}" "${_rc_session}" "${_rc_mm}" "${_rc_mp}" "${_rc_ma}" "${_rc_r_file}")
        _rc_decision=$(printf '%s\n' "${_rc_parsed}" | cut -d'|' -f1)
        _rc_feedback=$(printf '%s\n' "${_rc_parsed}" | cut -d'|' -f2)

        if [ "${_rc_decision}" != "SHIP" ] && [ "${_rc_decision}" != "REVISE" ]; then
            echo "[WARN] REVIEW PHASE FAILED - Invalid decision: ${_rc_decision}" >&2
            exit 1
        fi

        set_review "${_rc_session}" "${_rc_decision}" "${_rc_feedback}" "${_rc_iter}"

        if [ "${_rc_decision}" = "SHIP" ]; then
            echo ""
            echo "======================================================================"
            echo "  SHIPPED after ${_rc_iter} iteration(s)"
            echo "======================================================================"
            echo "Session: ${_rc_session}"
            echo "Complete: $(date)"
            exit 0
        else
            echo ""
            echo "REVISE - Feedback for next iteration:"
            echo "${_rc_feedback}"
            echo ""

            if [ "${_rc_adaptive}" = "true" ]; then
                _rc_new_prof=""
                _rc_trigger=""
                if test_quality_trigger "${_rc_w_out}" "${_rc_r_out}" "${_rc_feedback}"; then
                    _rc_trigger="quality"
                elif test_resource_trigger "${_rc_w_out}" "${_rc_r_out}" "${_rc_feedback}"; then
                    _rc_trigger="resource"
                fi
                if [ -n "${_rc_trigger}" ]; then
                    _rc_new_prof=$(get_adaptive_profile_switch "${_rc_strategy}" "${_rc_trigger}" "${_rc_cur_prof}")
                fi
                if [ -n "${_rc_new_prof}" ] && [ "${_rc_new_prof}" != "${_rc_cur_prof}" ]; then
                    _rc_sw=$(switch_adaptive_profile "${_rc_session}" "${_rc_new_prof}" "${_rc_cur_prof}")
                    _rc_cur_prof="${_rc_new_prof}"
                    IFS='|' read -r _rc_wm _rc_wp _rc_wa _rc_rm _rc_rp _rc_ra _rc_mm _rc_mp _rc_ma _rc_max_iter _rc_backoff _rc_throttle _rc_retries <<EOF
${_rc_sw}
EOF
                fi
            fi
        fi

        _rc_iter=$((_rc_iter + 1))
    done

    echo "[WARN] Max iterations (${_rc_max_iter}) reached" >&2
    exit 1
}

# =============================================================================
# MCP SERVER TOOL HANDLERS
# =============================================================================
handle_ralph_initialize() {
    _hri_id="${1}"
    _hri_params="${2:-"{}"}"

    _hri_session=$(printf '%s\n' "${_hri_params}" | jq -r '.sessionId // .session_id // "default"')
    _hri_task=$(printf '%s\n' "${_hri_params}" | jq -r '.task // empty')
    _hri_max_iter=$(printf '%s\n' "${_hri_params}" | jq -r '.maxIterations // .max_iterations // 10')
    _hri_backoff=$(printf '%s\n' "${_hri_params}" | jq -r '.initialBackoff // .initial_backoff // 5')
    _hri_throttle=$(printf '%s\n' "${_hri_params}" | jq -r '.throttleDelay // .throttle_delay // 0')
    _hri_retries=$(printf '%s\n' "${_hri_params}" | jq -r '.maxRetries // .max_retries // 3')
    _hri_wm=$(printf '%s\n' "${_hri_params}" | jq -r '.workerModel // .worker_model // empty')
    _hri_wp=$(printf '%s\n' "${_hri_params}" | jq -r '.workerProvider // .worker_provider // empty')
    _hri_wa=$(printf '%s\n' "${_hri_params}" | jq -r '.workerAgent // .worker_agent // "goose"')
    _hri_rm=$(printf '%s\n' "${_hri_params}" | jq -r '.reviewerModel // .reviewer_model // empty')
    _hri_rp=$(printf '%s\n' "${_hri_params}" | jq -r '.reviewerProvider // .reviewer_provider // empty')
    _hri_ra=$(printf '%s\n' "${_hri_params}" | jq -r '.reviewerAgent // .reviewer_agent // "goose"')
    _hri_mm=$(printf '%s\n' "${_hri_params}" | jq -r --arg m "${MONITOR_MODEL:-}" '.monitorModel // .monitor_model // $m // empty')
    _hri_mp=$(printf '%s\n' "${_hri_params}" | jq -r --arg p "${MONITOR_PROVIDER:-}" '.monitorProvider // .monitor_provider // $p // empty')
    _hri_ma=$(printf '%s\n' "${_hri_params}" | jq -r --arg a "${MONITOR_AGENT:-goose}" '.monitorAgent // .monitor_agent // $a // "goose"')
    _hri_enforced=$(printf '%s\n' "${_hri_params}" | jq -r 'if (.crossModelReviewEnforced == false or .cross_model_review_enforced == false) then "false" else "true" end')
    _hri_wg=$(printf '%s\n' "${_hri_params}" | jq -r '.workGuidelines // .work_guidelines // empty')
    _hri_rg=$(printf '%s\n' "${_hri_params}" | jq -r '.reviewGuidelines // .review_guidelines // empty')

    if [ -z "${_hri_task}" ]; then
        json_response "${_hri_id}" "" "$(mcp_error -32602 "Task is required")"
        return
    fi

    set_task "${_hri_session}" "${_hri_task}"
    set_config "${_hri_session}" "${_hri_wm}" "${_hri_wp}" "${_hri_rm}" "${_hri_rp}" "${_hri_max_iter}" "${_hri_enforced}" "${_hri_wa}" "${_hri_ra}" "${_hri_wg}" "${_hri_rg}" "${_hri_mm}" "${_hri_mp}" "${_hri_ma}" "${_hri_backoff}" "${_hri_throttle}" "${_hri_retries}"

    _hri_val=$(validate_cross_model "${_hri_session}")
    _hri_status=$(get_status "${_hri_session}" "${_hri_max_iter}")

    _hri_res=$(jq -n \
        --arg msg "Ralph Loop initialized for session \"${_hri_session}\"" \
        --argjson status "${_hri_status}" \
        --argjson validation "${_hri_val}" \
        --argjson enforced "${_hri_enforced}" \
        '{success: true, message: $msg, status: $status, crossModelReview: {enforced: $enforced, valid: $validation.valid, warning: $validation.warning}}')

    json_response "${_hri_id}" "${_hri_res}"
}

handle_get_task() {
    _hgt_id="${1}"
    _hgt_params="${2:-"{}"}"
    _hgt_session=$(printf '%s\n' "${_hgt_params}" | jq -r '.sessionId // .session_id // "default"')

    _hgt_task=$(get_task "${_hgt_session}")

    if [ -z "${_hgt_task}" ]; then
        json_response "${_hgt_id}" "" "$(mcp_error -32602 "No task found. Initialize the session first with ralph_loop_initialize.")"
        return
    fi

    _hgt_res=$(printf '%s\n' "${_hgt_task}" | jq '{success: true, task: .task, createdAt: .createdAt}')
    json_response "${_hgt_id}" "${_hgt_res}"
}

handle_submit_work() {
    _hsw_id="${1}"
    _hsw_params="${2:-"{}"}"

    _hsw_session=$(printf '%s\n' "${_hsw_params}" | jq -r '.sessionId // .session_id // "default"')
    _hsw_work=$(printf '%s\n' "${_hsw_params}" | jq -r '.work // empty')
    _hsw_summary=$(printf '%s\n' "${_hsw_params}" | jq -r '.summary // empty')
    _hsw_iter=$(printf '%s\n' "${_hsw_params}" | jq -r '.iteration // empty')

    if [ -z "${_hsw_work}" ] || [ -z "${_hsw_summary}" ] || [ -z "${_hsw_iter}" ]; then
        json_response "${_hsw_id}" "" "$(mcp_error -32602 "work, summary, and iteration are required")"
        return
    fi

    set_work "${_hsw_session}" "${_hsw_work}" "${_hsw_summary}" "${_hsw_iter}"
    _hsw_status=$(get_status "${_hsw_session}")

    _hsw_res=$(jq -n \
        --arg msg "Work submitted for iteration ${_hsw_iter}" \
        --argjson status "${_hsw_status}" \
        '{success: true, message: $msg, status: $status}')

    json_response "${_hsw_id}" "${_hsw_res}"
}

handle_get_work() {
    _hgw_id="${1}"
    _hgw_params="${2:-"{}"}"
    _hgw_session=$(printf '%s\n' "${_hgw_params}" | jq -r '.sessionId // .session_id // "default"')

    _hgw_work=$(get_work "${_hgw_session}")

    if [ -z "${_hgw_work}" ]; then
        json_response "${_hgw_id}" "" "$(mcp_error -32602 "No work submitted yet. Worker must submit work first.")"
        return
    fi

    _hgw_res=$(printf '%s\n' "${_hgw_work}" | jq '{success: true, work: .work, summary: .summary, iteration: .iteration, submittedAt: .submittedAt}')
    json_response "${_hgw_id}" "${_hgw_res}"
}

handle_submit_review() {
    _hsr_id="${1}"
    _hsr_params="${2:-"{}"}"

    _hsr_session=$(printf '%s\n' "${_hsr_params}" | jq -r '.sessionId // .session_id // "default"')
    _hsr_decision=$(printf '%s\n' "${_hsr_params}" | jq -r '.decision // empty')
    _hsr_feedback=$(printf '%s\n' "${_hsr_params}" | jq -r '.feedback // empty')
    _hsr_iter=$(printf '%s\n' "${_hsr_params}" | jq -r '.iteration // empty')

    if [ -z "${_hsr_decision}" ] || [ -z "${_hsr_iter}" ]; then
        json_response "${_hsr_id}" "" "$(mcp_error -32602 "decision and iteration are required")"
        return
    fi

    if [ "${_hsr_decision}" = "REVISE" ] && [ -z "${_hsr_feedback}" ]; then
        json_response "${_hsr_id}" "" "$(mcp_error -32602 "Feedback is required when decision is REVISE")"
        return
    fi

    set_review "${_hsr_session}" "${_hsr_decision}" "${_hsr_feedback}" "${_hsr_iter}"
    _hsr_status=$(get_status "${_hsr_session}")

    _hsr_res=$(jq -n \
        --arg msg "Review submitted: ${_hsr_decision}" \
        --arg decision "${_hsr_decision}" \
        --arg feedback "${_hsr_feedback}" \
        --argjson status "${_hsr_status}" \
        '{success: true, message: $msg, decision: $decision, feedback: $feedback, status: $status}')

    json_response "${_hsr_id}" "${_hsr_res}"
}

handle_get_feedback() {
    _hgf_id="${1}"
    _hgf_params="${2:-"{}"}"
    _hgf_session=$(printf '%s\n' "${_hgf_params}" | jq -r '.sessionId // .session_id // "default"')

    _hgf_rev_res=$(get_review_result "${_hgf_session}")
    _hgf_feedback=$(get_feedback "${_hgf_session}")
    _hgf_status=$(get_status "${_hgf_session}")

    if [ -z "${_hgf_rev_res}" ]; then
        json_response "${_hgf_id}" "" "$(mcp_error -32602 "No review completed yet. Reviewer must submit review first.")"
        return
    fi

    if [ "${_hgf_rev_res}" = "SHIP" ]; then
        _hgf_res=$(jq -n \
            --argjson status "${_hgf_status}" \
            '{success: true, shipped: true, message: "Work approved! SHIPPED.", status: $status}')
        json_response "${_hgf_id}" "${_hgf_res}"
        return
    fi

    _hgf_res=$(jq -n \
        --arg feedback "${_hgf_feedback}" \
        --argjson iteration "$(printf '%s\n' "${_hgf_status}" | jq -r '.currentIteration')" \
        --argjson status "${_hgf_status}" \
        '{success: true, shipped: false, feedback: $feedback, iteration: $iteration, status: $status}')
    json_response "${_hgf_id}" "${_hgf_res}"
}

handle_get_status() {
    _hgs_id="${1}"
    _hgs_params="${2:-"{}"}"
    _hgs_session=$(printf '%s\n' "${_hgs_params}" | jq -r '.sessionId // .session_id // "default"')

    _hgs_cfg=$(get_config "${_hgs_session}")
    if [ -n "${_hgs_cfg}" ]; then
        _hgs_max_iter=$(printf '%s\n' "${_hgs_cfg}" | jq -r '.maxIterations // 10')
    else
        _hgs_max_iter=10
    fi

    _hgs_status=$(get_status "${_hgs_session}" "${_hgs_max_iter}")
    _hgs_res=$(printf '%s\n' "${_hgs_status}" | jq '{success: true} + .')
    json_response "${_hgs_id}" "${_hgs_res}"
}

handle_get_config() {
    _hgc_id="${1}"
    _hgc_params="${2:-"{}"}"
    _hgc_session=$(printf '%s\n' "${_hgc_params}" | jq -r '.sessionId // .session_id // "default"')

    _hgc_cfg=$(get_config "${_hgc_session}")

    if [ -z "${_hgc_cfg}" ]; then
        json_response "${_hgc_id}" "" "$(mcp_error -32602 "No configuration found. Initialize the session first with ralph_loop_initialize.")"
        return
    fi

    _hgc_val=$(validate_cross_model "${_hgc_session}")

    _hgc_res=$(jq -n \
        --argjson config "${_hgc_cfg}" \
        --argjson validation "${_hgc_val}" \
        '{success: true, config: {workerModel: $config.workerModel, workerProvider: $config.workerProvider, workerAgent: $config.workerAgent, reviewerModel: $config.reviewerModel, reviewerProvider: $config.reviewerProvider, reviewerAgent: $config.reviewerAgent, monitorModel: $config.monitorModel, monitorProvider: $config.monitorProvider, monitorAgent: $config.monitorAgent, maxIterations: $config.maxIterations, crossModelReviewEnforced: $config.crossModelReviewEnforced, workGuidelines: $config.workGuidelines, reviewGuidelines: $config.reviewGuidelines, configuredAt: $config.configuredAt}, crossModelReview: {enforced: $config.crossModelReviewEnforced, valid: $validation.valid, warning: $validation.warning}}')

    json_response "${_hgc_id}" "${_hgc_res}"
}

handle_reset() {
    _hr_id="${1}"
    _hr_params="${2:-"{}"}"
    _hr_session=$(printf '%s\n' "${_hr_params}" | jq -r '.sessionId // .session_id // "default"')

    reset_session "${_hr_session}"

    _hr_res=$(jq -n --arg msg "Session \"${_hr_session}\" has been reset" '{success: true, message: $msg}')
    json_response "${_hr_id}" "${_hr_res}"
}

handle_block() {
    _hb_id="${1}"
    _hb_params="${2:-"{}"}"

    _hb_session=$(printf '%s\n' "${_hb_params}" | jq -r '.sessionId // .session_id // "default"')
    _hb_reason=$(printf '%s\n' "${_hb_params}" | jq -r '.reason // empty')

    if [ -z "${_hb_reason}" ]; then
        json_response "${_hb_id}" "" "$(mcp_error -32602 "Reason is required for blocking")"
        return
    fi

    block_iteration "${_hb_session}" "${_hb_reason}"

    _hb_res=$(jq -n --arg msg "Iteration blocked" --arg reason "${_hb_reason}" '{success: true, message: $msg, reason: $reason}')
    json_response "${_hb_id}" "${_hb_res}"
}

handle_run() {
    _hrun_id="${1}"
    _hrun_params="${2:-"{}"}"

    _hrun_session=$(printf '%s\n' "${_hrun_params}" | jq -r '.sessionId // .session_id // "default"')
    _hrun_task=$(printf '%s\n' "${_hrun_params}" | jq -r '.task // empty')
    _hrun_max_iter=$(printf '%s\n' "${_hrun_params}" | jq -r '.maxIterations // .max_iterations // 10')
    _hrun_backoff=$(printf '%s\n' "${_hrun_params}" | jq -r '.initialBackoff // .initial_backoff // 5')
    _hrun_throttle=$(printf '%s\n' "${_hrun_params}" | jq -r '.throttleDelay // .throttle_delay // 0')
    _hrun_retries=$(printf '%s\n' "${_hrun_params}" | jq -r '.maxRetries // .max_retries // 3')
    _hrun_adaptive=$(printf '%s\n' "${_hrun_params}" | jq -r '.enableAdaptive // .enable_adaptive // false')
    _hrun_strategy=$(printf '%s\n' "${_hrun_params}" | jq -r '.adaptiveStrategy // .adaptive_strategy // "balanced"')
    _hrun_cur_prof=$(printf '%s\n' "${_hrun_params}" | jq -r '.profile // empty')
    _hrun_wm=$(printf '%s\n' "${_hrun_params}" | jq -r '.workerModel // .worker_model // empty')
    _hrun_wp=$(printf '%s\n' "${_hrun_params}" | jq -r '.workerProvider // .worker_provider // empty')
    _hrun_wa=$(printf '%s\n' "${_hrun_params}" | jq -r '.workerAgent // .worker_agent // "goose"')
    _hrun_rm=$(printf '%s\n' "${_hrun_params}" | jq -r '.reviewerModel // empty')
    _hrun_rp=$(printf '%s\n' "${_hrun_params}" | jq -r '.reviewerProvider // empty')
    _hrun_ra=$(printf '%s\n' "${_hrun_params}" | jq -r '.reviewerAgent // "goose"')
    _hrun_enforced=$(printf '%s\n' "${_hrun_params}" | jq -r 'if .crossModelReviewEnforced == false then "false" else "true" end')
    _hrun_wg=$(printf '%s\n' "${_hrun_params}" | jq -r '.workGuidelines // empty')
    _hrun_rg=$(printf '%s\n' "${_hrun_params}" | jq -r '.reviewGuidelines // empty')
    _hrun_mm=$(printf '%s\n' "${_hrun_params}" | jq -r --arg m "${MONITOR_MODEL:-}" '.monitorModel // $m // empty')
    _hrun_mp=$(printf '%s\n' "${_hrun_params}" | jq -r --arg p "${MONITOR_PROVIDER:-}" '.monitorProvider // $p // empty')
    _hrun_ma=$(printf '%s\n' "${_hrun_params}" | jq -r --arg a "${MONITOR_AGENT:-goose}" '.monitorAgent // $a // "goose"')

    if [ -z "${_hrun_task}" ]; then
        json_response "${_hrun_id}" "" "$(mcp_error -32602 "Task is required")"
        return
    fi

    if [ -z "${_hrun_wm}" ] || [ -z "${_hrun_wp}" ] || [ -z "${_hrun_rm}" ] || [ -z "${_hrun_rp}" ]; then
        json_response "${_hrun_id}" "" "$(mcp_error -32602 "workerModel, workerProvider, reviewerModel, and reviewerProvider are required")"
        return
    fi

    set_task "${_hrun_session}" "${_hrun_task}"
    set_config "${_hrun_session}" "${_hrun_wm}" "${_hrun_wp}" "${_hrun_rm}" "${_hrun_rp}" "${_hrun_max_iter}" "${_hrun_enforced}" "${_hrun_wa}" "${_hrun_ra}" "${_hrun_wg}" "${_hrun_rg}" "${_hrun_mm}" "${_hrun_mp}" "${_hrun_ma}" "${_hrun_backoff}" "${_hrun_throttle}" "${_hrun_retries}"

    if [ "${_hrun_adaptive}" = "true" ]; then
        case "${_hrun_strategy}" in
            quality|price|balanced) ;;
            *) _hrun_strategy="balanced" ;;
        esac
        if [ -z "${_hrun_cur_prof}" ]; then
            case "${_hrun_strategy}" in
                quality) _hrun_cur_prof="ultra" ;;
                price)   _hrun_cur_prof="lite" ;;
                *)       _hrun_cur_prof="pro" ;;
            esac
        fi
    fi

    _hrun_feedback=""
    _hrun_i=1

    while [ "${_hrun_i}" -le "${_hrun_max_iter}" ]; do
        _hrun_existing="false"
        if [ "${_hrun_i}" -gt 1 ]; then
            _hrun_existing="true"
        fi

        _hrun_w_out=$(call_llm_worker "${_hrun_task}" "${_hrun_feedback}" "${_hrun_i}" "${_hrun_session}" "${_hrun_wm}" "${_hrun_wp}" "${_hrun_wa}" "${_hrun_wg}" "${_hrun_existing}" || true)

        case "${_hrun_w_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                if [ "${_hrun_adaptive}" = "true" ]; then
                    _hrun_new_prof=$(get_adaptive_profile_switch "${_hrun_strategy}" "resource" "${_hrun_cur_prof}")
                    if [ -n "${_hrun_new_prof}" ] && [ "${_hrun_new_prof}" != "${_hrun_cur_prof}" ]; then
                        _hrun_sw=$(switch_adaptive_profile "${_hrun_session}" "${_hrun_new_prof}" "${_hrun_cur_prof}")
                        _hrun_cur_prof="${_hrun_new_prof}"
                        IFS='|' read -r _hrun_wm _hrun_wp _hrun_wa _hrun_rm _hrun_rp _hrun_ra _hrun_mm _hrun_mp _hrun_ma _hrun_max_iter _hrun_backoff _hrun_throttle _hrun_retries <<EOF
${_hrun_sw}
EOF
                        _hrun_w_out=$(call_llm_worker "${_hrun_task}" "${_hrun_feedback}" "${_hrun_i}" "${_hrun_session}" "${_hrun_wm}" "${_hrun_wp}" "${_hrun_wa}" "${_hrun_wg}" "${_hrun_existing}" || true)
                    fi
                fi
                ;;
        esac

        case "${_hrun_w_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                block_iteration "${_hrun_session}" "WORK PHASE FAILED - Rate limit or quota error from worker LLM"
                json_response "${_hrun_id}" "" "$(mcp_error -32603 "WORK PHASE FAILED - Rate limit, quota error, or no output from worker")"
                return
                ;;
        esac

        _hrun_w_file="$(get_state_file "${_hrun_session}" "work.out")"
        printf '%s\n' "${_hrun_w_out}" > "${_hrun_w_file}"

        _hrun_parsed=$(parse_worker_output "${_hrun_w_out}" "${_hrun_session}" "${_hrun_mm}" "${_hrun_mp}" "${_hrun_ma}" "${_hrun_w_file}")
        _hrun_work=$(printf '%s\n' "${_hrun_parsed}" | cut -d'|' -f1)
        _hrun_summary=$(printf '%s\n' "${_hrun_parsed}" | cut -d'|' -f2)

        if [ -z "${_hrun_work}" ] || [ -z "${_hrun_summary}" ]; then
            json_response "${_hrun_id}" "" "$(mcp_error -32603 "WORK PHASE FAILED - Could not parse output")"
            return
        fi

        set_work "${_hrun_session}" "${_hrun_work}" "${_hrun_summary}" "${_hrun_i}"

        _hrun_r_out=$(call_llm_reviewer "${_hrun_task}" "${_hrun_work}" "${_hrun_summary}" "${_hrun_i}" "${_hrun_session}" "${_hrun_rm}" "${_hrun_rp}" "${_hrun_ra}" "${_hrun_rg}" "${_hrun_existing}" || true)

        case "${_hrun_r_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                if [ "${_hrun_adaptive}" = "true" ]; then
                    _hrun_new_prof=$(get_adaptive_profile_switch "${_hrun_strategy}" "resource" "${_hrun_cur_prof}")
                    if [ -n "${_hrun_new_prof}" ] && [ "${_hrun_new_prof}" != "${_hrun_cur_prof}" ]; then
                        _hrun_sw=$(switch_adaptive_profile "${_hrun_session}" "${_hrun_new_prof}" "${_hrun_cur_prof}")
                        _hrun_cur_prof="${_hrun_new_prof}"
                        IFS='|' read -r _hrun_wm _hrun_wp _hrun_wa _hrun_rm _hrun_rp _hrun_ra _hrun_mm _hrun_mp _hrun_ma _hrun_max_iter _hrun_backoff _hrun_throttle _hrun_retries <<EOF
${_hrun_sw}
EOF
                        _hrun_r_out=$(call_llm_reviewer "${_hrun_task}" "${_hrun_work}" "${_hrun_summary}" "${_hrun_i}" "${_hrun_session}" "${_hrun_rm}" "${_hrun_rp}" "${_hrun_ra}" "${_hrun_rg}" "${_hrun_existing}" || true)
                    fi
                fi
                ;;
        esac

        case "${_hrun_r_out}" in
            RATE_LIMIT_EXCEEDED*|'')
                block_iteration "${_hrun_session}" "REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM"
                json_response "${_hrun_id}" "" "$(mcp_error -32603 "REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer")"
                return
                ;;
        esac

        _hrun_r_file="$(get_state_file "${_hrun_session}" "review.out")"
        printf '%s\n' "${_hrun_r_out}" > "${_hrun_r_file}"

        _hrun_parsed=$(parse_reviewer_output "${_hrun_r_out}" "${_hrun_session}" "${_hrun_mm}" "${_hrun_mp}" "${_hrun_ma}" "${_hrun_r_file}")
        _hrun_decision=$(printf '%s\n' "${_hrun_parsed}" | cut -d'|' -f1)
        _hrun_feedback=$(printf '%s\n' "${_hrun_parsed}" | cut -d'|' -f2)

        if [ "${_hrun_decision}" != "SHIP" ] && [ "${_hrun_decision}" != "REVISE" ]; then
            json_response "${_hrun_id}" "" "$(mcp_error -32603 "REVIEW PHASE FAILED - Invalid decision: ${_hrun_decision}")"
            return
        fi

        set_review "${_hrun_session}" "${_hrun_decision}" "${_hrun_feedback}" "${_hrun_i}"

        if [ "${_hrun_decision}" = "SHIP" ]; then
            _hrun_status=$(get_status "${_hrun_session}" "${_hrun_max_iter}")
            _hrun_res=$(jq -n --arg msg "SHIPPED after ${_hrun_i} iteration(s)" --argjson status "${_hrun_status}" --argjson iter "${_hrun_i}" '{success: true, message: $msg, status: $status, shipped: true, iterations: $iter}')
            json_response "${_hrun_id}" "${_hrun_res}"
            return
        fi

        if [ "${_hrun_adaptive}" = "true" ]; then
            _hrun_new_prof=""
            _hrun_trigger=""
            if test_quality_trigger "${_hrun_w_out}" "${_hrun_r_out}" "${_hrun_feedback}"; then
                _hrun_trigger="quality"
            elif test_resource_trigger "${_hrun_w_out}" "${_hrun_r_out}" "${_hrun_feedback}"; then
                _hrun_trigger="resource"
            fi
            if [ -n "${_hrun_trigger}" ]; then
                _hrun_new_prof=$(get_adaptive_profile_switch "${_hrun_strategy}" "${_hrun_trigger}" "${_hrun_cur_prof}")
            fi
            if [ -n "${_hrun_new_prof}" ] && [ "${_hrun_new_prof}" != "${_hrun_cur_prof}" ]; then
                _hrun_sw=$(switch_adaptive_profile "${_hrun_session}" "${_hrun_new_prof}" "${_hrun_cur_prof}")
                _hrun_cur_prof="${_hrun_new_prof}"
                IFS='|' read -r _hrun_wm _hrun_wp _hrun_wa _hrun_rm _hrun_rp _hrun_ra _hrun_mm _hrun_mp _hrun_ma _hrun_max_iter _hrun_backoff _hrun_throttle _hrun_retries <<EOF
${_hrun_sw}
EOF
            fi
        fi

        _hrun_i=$((_hrun_i + 1))
    done

    _hrun_status=$(get_status "${_hrun_session}" "${_hrun_max_iter}")
    _hrun_res=$(jq -n --arg msg "Max iterations (${_hrun_max_iter}) reached" --argjson status "${_hrun_status}" '{success: false, message: $msg, status: $status, shipped: false}')
    json_response "${_hrun_id}" "${_hrun_res}"
}

# Override SDK handle_tools_list to expose the 11 Ralph Loop MCP tools
handle_tools_list() {
    _htl_id="${1}"
    _htl_tools='[
  {
    "name": "ralph_loop_initialize",
    "description": "Initialize a new Ralph Loop session with a task, model configuration, and guidelines",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Unique session identifier (default: '\''default'\'')" },
        "task": { "type": "string", "description": "The task or feature description for the worker to implement" },
        "maxIterations": { "type": "integer", "description": "Maximum number of iterations (-1 for unlimited, default: 10)" },
        "workerModel": { "type": "string", "description": "Worker LLM model name (e.g., '\''claude-3-5-sonnet'\'')" },
        "workerProvider": { "type": "string", "description": "Worker provider (anthropic, openai, google, copilot, goose)" },
        "workerAgent": { "type": "string", "description": "Worker agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "reviewerModel": { "type": "string", "description": "Reviewer LLM model name (e.g., '\''gpt-4o'\'')" },
        "reviewerProvider": { "type": "string", "description": "Reviewer provider (anthropic, openai, google, copilot, goose)" },
        "reviewerAgent": { "type": "string", "description": "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "monitorModel": { "type": "string", "description": "Monitoring agent model name (fallback supervisor)" },
        "monitorProvider": { "type": "string", "description": "Monitoring agent provider (anthropic, openai, google, copilot, goose)" },
        "monitorAgent": { "type": "string", "description": "Monitoring agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "crossModelReviewEnforced": { "type": "boolean", "description": "Enforce cross-model review validation between worker and reviewer (default: true)" },
        "workGuidelines": { "type": "string", "description": "Path to work recipe or guidelines file" },
        "reviewGuidelines": { "type": "string", "description": "Path to review recipe or guidelines file" }
      },
      "required": ["task"]
    }
  },
  {
    "name": "ralph_loop_get_task",
    "description": "Get the current task for the worker phase",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_submit_work",
    "description": "Submit work results and summary from worker phase",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "work": { "type": "string", "description": "Complete work output / implementation" },
        "summary": { "type": "string", "description": "Summary of changes made" },
        "iteration": { "type": "integer", "description": "Current iteration number" }
      },
      "required": ["work", "summary", "iteration"]
    }
  },
  {
    "name": "ralph_loop_get_work",
    "description": "Get worker'\''s submitted work for reviewer phase",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_submit_review",
    "description": "Submit review decision (SHIP or REVISE) with feedback",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "decision": { "type": "string", "enum": ["SHIP", "REVISE"], "description": "Review decision: SHIP to approve, REVISE to request changes" },
        "feedback": { "type": "string", "description": "Actionable feedback for revision (required if decision is REVISE)" },
        "iteration": { "type": "integer", "description": "Current iteration number" }
      },
      "required": ["decision", "iteration"]
    }
  },
  {
    "name": "ralph_loop_get_feedback",
    "description": "Get reviewer feedback for next iteration",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_get_status",
    "description": "Get current session status, phase, iteration, and configuration",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_get_config",
    "description": "Get worker, reviewer, and monitor configuration for a session",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_reset",
    "description": "Reset and clear all state and history for a session",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_block",
    "description": "Block the current iteration with a reason",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "reason": { "type": "string", "description": "Reason why the loop cannot proceed" }
      },
      "required": ["reason"]
    }
  },
  {
    "name": "ralph_loop_run",
    "description": "Run complete automated Ralph Loop (initialization -> orchestration -> execution -> state management)",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "task": { "type": "string", "description": "Task description to accomplish" },
        "maxIterations": { "type": "integer", "description": "Maximum number of iterations (-1 for unlimited, default: 10)" },
        "workerModel": { "type": "string", "description": "Worker model name" },
        "workerProvider": { "type": "string", "description": "Worker provider (anthropic, openai, google, copilot, goose)" },
        "workerAgent": { "type": "string", "description": "Worker agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "reviewerModel": { "type": "string", "description": "Reviewer model name" },
        "reviewerProvider": { "type": "string", "description": "Reviewer provider (anthropic, openai, google, copilot, goose)" },
        "reviewerAgent": { "type": "string", "description": "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "monitorModel": { "type": "string", "description": "Monitor model name" },
        "monitorProvider": { "type": "string", "description": "Monitor provider" },
        "monitorAgent": { "type": "string", "description": "Monitor agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "crossModelReviewEnforced": { "type": "boolean", "description": "Enforce cross-model review validation (default: true)" },
        "workGuidelines": { "type": "string", "description": "Path to work recipe or guidelines file" },
        "reviewGuidelines": { "type": "string", "description": "Path to review recipe or guidelines file" },
        "enableAdaptive": { "type": "boolean", "description": "Enable adaptive profile switching (default: false)" },
        "adaptiveStrategy": { "type": "string", "enum": ["quality", "price", "balanced"], "description": "Adaptive switching strategy (default: balanced)" }
      },
      "required": ["task", "workerModel", "workerProvider", "reviewerModel", "reviewerProvider"]
    }
  }
]'
    _htl_res=$(jq -cn --argjson tools "${_htl_tools}" '{tools: $tools}')
    json_response "${_htl_id}" "${_htl_res}"
}

# Dispatch a named tool invocation (supports both ralph_loop_* and ralf_loop_* aliases)
dispatch_ralph_tool() {
    _drt_id="${1}"
    _drt_name="${2}"
    _drt_args="${3:-"{}"}"

    case "${_drt_name}" in
        ralph_loop_initialize|ralf_loop_initialize)
            handle_ralph_initialize "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_get_task|ralf_loop_get_task)
            handle_get_task "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_submit_work|ralf_loop_submit_work)
            handle_submit_work "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_get_work|ralf_loop_get_work)
            handle_get_work "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_submit_review|ralf_loop_submit_review)
            handle_submit_review "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_get_feedback|ralf_loop_get_feedback)
            handle_get_feedback "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_get_status|ralf_loop_get_status)
            handle_get_status "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_get_config|ralf_loop_get_config)
            handle_get_config "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_reset|ralf_loop_reset)
            handle_reset "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_block|ralf_loop_block)
            handle_block "${_drt_id}" "${_drt_args}"
            ;;
        ralph_loop_run|ralf_loop_run)
            handle_run "${_drt_id}" "${_drt_args}"
            ;;
        *)
            json_response "${_drt_id}" "" "$(mcp_error -32601 "Unknown tool: ${_drt_name}")"
            ;;
    esac
}

# Override SDK handle_tools_call
handle_tools_call() {
    _htc_id="${1}"
    _htc_params="${2:-"{}"}"
    _htc_name=$(printf '%s' "${_htc_params}" | jq -r '.name // empty' 2>/dev/null || echo "")
    _htc_args=$(printf '%s' "${_htc_params}" | jq -c '.arguments // {}' 2>/dev/null || echo "{}")
    dispatch_ralph_tool "${_htc_id}" "${_htc_name}" "${_htc_args}"
}

# Support direct JSON-RPC method calls for tool names as well
mcp_custom_method_handler() {
    _mcmh_id="${1}"
    _mcmh_method="${2}"
    _mcmh_params="${3:-"{}"}"
    _mcmh_notif="${4:-false}"

    case "${_mcmh_method}" in
        ralph_loop_*|ralf_loop_*)
            dispatch_ralph_tool "${_mcmh_id}" "${_mcmh_method}" "${_mcmh_params}"
            ;;
        *)
            if [ "${_mcmh_notif}" != "true" ] && [ "${_mcmh_id}" != "null" ] && [ -n "${_mcmh_id}" ]; then
                json_response "${_mcmh_id}" "" "$(mcp_error -32601 "Method not found: ${_mcmh_method}")"
            fi
            ;;
    esac
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
case "${0##*/}" in
    ralph-wiggum-loop.sh|ralph-wiggum-loop)
        if [ $# -eq 0 ]; then
            mcp_main
            exit 0
        elif [ "${1}" = "--stdio" ]; then
            export MCP_TRANSPORT="stdio"
            mcp_main
            exit 0
        elif [ "${1}" = "--http-worker" ]; then
            handle_http_request_stream
            exit 0
        elif [ "${1}" = "--http" ] || [ "${1}" = "--streamable-http" ]; then
            export MCP_TRANSPORT="streamable-http"
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                    --port) shift; export MCP_HTTP_PORT="${1:-8080}"; export MCP_HTTP_LISTEN="true" ;;
                    --host) shift; export MCP_HTTP_HOST="${1:-127.0.0.1}"; export MCP_HTTP_LISTEN="true" ;;
                    --listen) export MCP_HTTP_LISTEN="true" ;;
                esac
                shift
            done
            mcp_main
            exit 0
        else
            run_cli "$@"
            exit $?
        fi
        ;;
esac
