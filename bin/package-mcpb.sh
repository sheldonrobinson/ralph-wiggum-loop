#!/usr/bin/env sh
# =============================================================================
# package-mcpb.sh (POSIX sh compliant)
# Builds multi-package MCPB bundles (ralph-wiggum-loop.sh.mcpb and
# ralph-wiggum-loop.pwsh.mcpb), renders platform-specific mcp.json from
# packaging/mcpb/mcp.template.json, and updates server.json with SHA-256 hashes
# for the Official MCP Registry.
# =============================================================================

set -eu

# Ensure jq is in PATH using POSIX parameter expansion (${PATH#*dir})
if ! command -v jq >/dev/null 2>&1; then
    for _d in /opt/homebrew/bin /usr/local/bin "${HOME:-}/.local/bin"; do
        if [ -n "${_d}" ] && [ -d "${_d}" ] && [ "${PATH#*${_d}}" = "${PATH}" ]; then
            PATH="${_d}:${PATH}"
        fi
    done
    export PATH
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION=""
REPO_OWNER="sheldonrobinson"
REPO_NAME="ralph-wiggum-loop"
OUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version|-Version)
            VERSION="${2:-}"
            shift 2
            ;;
        --repo-owner|-RepoOwner)
            REPO_OWNER="${2:-sheldonrobinson}"
            shift 2
            ;;
        --repo-name|-RepoName)
            REPO_NAME="${2:-ralph-wiggum-loop}"
            shift 2
            ;;
        --out-dir|-OutDir)
            OUT_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: package-mcpb.sh [--version <ver>] [--repo-owner <owner>] [--repo-name <name>] [--out-dir <dir>]
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [ -z "${VERSION}" ]; then
    if [ -f "${REPO_ROOT}/plugin.json" ] && command -v jq >/dev/null 2>&1; then
        VERSION="$(jq -r '.version // "1.1.0"' "${REPO_ROOT}/plugin.json")"
    else
        VERSION="1.1.0"
    fi
fi

if [ -z "${OUT_DIR}" ]; then
    OUT_DIR="${REPO_ROOT}/dist"
fi

mkdir -p "${OUT_DIR}"

TEMP_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'ralph-mcpb')"
cleanup() {
    rm -rf "${TEMP_BASE}"
}
trap cleanup EXIT

copy_rel_file() {
    src_root="$1"
    stage_root="$2"
    rel_path="$3"
    src="${src_root}/${rel_path}"
    dst="${stage_root}/${rel_path}"
    if [ ! -f "${src}" ]; then
        echo "Error: Required bundle file not found: ${src}" >&2
        exit 1
    fi
    mkdir -p "$(dirname "${dst}")"
    cp "${src}" "${dst}"
}

render_platform_mcp_json() {
    template_path="$1"
    dest_path="$2"
    target_platform="$3"

    if [ "${target_platform}" = "sh" ]; then
        cmd="sh"
        args_json='["-c", "command -v jq >/dev/null 2>&1 || { for d in /opt/homebrew/bin /usr/local/bin; do [ -d \"$d\" ] && [ \"${PATH#*$d}\" = \"$PATH\" ] && PATH=\"$d:$PATH\"; done; export PATH; }; exec sh \"$0\" \"$@\"", "${PLUGIN_ROOT}/bin/ralph-wiggum-loop.sh", "--stdio"]'
    else
        cmd="pwsh"
        args_json='["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/ralph-wiggum-loop.ps1", "-Stdio"]'
    fi

    rendered="$(sed 's/{{MCP_STDIO_ARGS_JSON}}/[]/g' "${template_path}" | jq \
        --arg cmd "${cmd}" \
        --argjson args "${args_json}" \
        '.mcpServers["ralph-wiggum-loop"].command = $cmd | .mcpServers["ralph-wiggum-loop"].args = $args')"

    if [ "${target_platform}" = "pwsh" ] && command -v jq >/dev/null 2>&1; then
        printf '%s\n' "${rendered}" | jq '.mcpServers["ralph-wiggum-loop-powershell"] = {
            "type": "stdio",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/ralph-wiggum-loop.ps1", "-Stdio"],
            "cwd": "${PLUGIN_ROOT}",
            "env": {
                "RALPH_STATE_BASE": "${PLUGIN_DATA}/state",
                "RALPH_RECIPE_DIR": "${PLUGIN_ROOT}/recipes"
            }
        }' > "${dest_path}"
    elif command -v jq >/dev/null 2>&1; then
        printf '%s\n' "${rendered}" | jq '.' > "${dest_path}"
    else
        printf '%s\n' "${rendered}" > "${dest_path}"
    fi
}

create_mcpb_archive() {
    stage_dir="$1"
    dest_mcpb="$2"
    rm -f "${dest_mcpb}"
    if command -v zip >/dev/null 2>&1; then
        (cd "${stage_dir}" && zip -q -r "${dest_mcpb}" .)
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "${stage_dir}" "${dest_mcpb}" <<'PY'
import os, sys, zipfile
stage_dir, dest_mcpb = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest_mcpb, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(stage_dir):
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = os.path.relpath(full, stage_dir).replace("\\", "/")
            zf.write(full, rel)
PY
    elif command -v pwsh >/dev/null 2>&1; then
        pwsh -NoProfile -Command "Compress-Archive -Path '${stage_dir}/*' -DestinationPath '${dest_mcpb}.zip' -Force; Move-Item -LiteralPath '${dest_mcpb}.zip' -Destination '${dest_mcpb}' -Force"
    elif command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "& '${SCRIPT_DIR}/package-mcpb.ps1' -Version '${VERSION}' -RepoOwner '${REPO_OWNER}' -RepoName '${REPO_NAME}' -OutDir '${OUT_DIR}'"
        exit 0
    else
        echo "Error: Neither zip, python3, nor pwsh found to create .mcpb archive." >&2
        exit 1
    fi
}

compute_sha256() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${file}" | awk '{print tolower($1)}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${file}" | awk '{print tolower($NF)}'
    else
        echo "Error: No SHA-256 tool found (sha256sum, shasum, openssl)." >&2
        exit 1
    fi
}

MCP_TEMPLATE_PATH="${REPO_ROOT}/packaging/mcpb/mcp.template.json"

# -----------------------------------------------------------------------------
# 1. Stage & Build ralph-wiggum-loop.sh.mcpb (POSIX sh edition: linux, darwin)
# -----------------------------------------------------------------------------
STAGE_SH="${TEMP_BASE}/sh"
mkdir -p "${STAGE_SH}"

if command -v jq >/dev/null 2>&1; then
    jq --arg ver "${VERSION}" '.version = $ver' "${REPO_ROOT}/packaging/mcpb/manifest.sh.json" > "${STAGE_SH}/manifest.json"
else
    cp "${REPO_ROOT}/packaging/mcpb/manifest.sh.json" "${STAGE_SH}/manifest.json"
fi

render_platform_mcp_json "${MCP_TEMPLATE_PATH}" "${STAGE_SH}/mcp.json" "sh"

for rel in \
    "bin/ralph-wiggum-loop.sh" \
    "bin/mcp-sdk.sh" \
    "bin/script-runner" \
    "bin/script-runner.sh" \
    "profiles/lite.json" \
    "profiles/plus.json" \
    "profiles/pro.json" \
    "profiles/super.json" \
    "profiles/ultra.json" \
    "skills/ralph-wiggum-loop/SKILL.md" \
    "skills/ralph-wiggum-loop/references/checklist.md" \
    "skills/ralph-wiggum-loop/references/spec-template.md" \
    "skills/ralph-wiggum-loop/scripts/setup-ralph-loop.sh" \
    "skills/ralph-wiggum-loop/scripts/start-http-server.sh" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/hooks.json" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/stop-hook.sh" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/commands/ralph-loop.md" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/commands/cancel-ralph.md" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/commands/help.md" \
    "plugin.json" \
    "LICENSE" \
    "README.md"
do
    copy_rel_file "${REPO_ROOT}" "${STAGE_SH}" "${rel}"
done
chmod +x "${STAGE_SH}/bin/ralph-wiggum-loop.sh" "${STAGE_SH}/bin/mcp-sdk.sh" "${STAGE_SH}/bin/script-runner" "${STAGE_SH}/bin/script-runner.sh"

MCPB_SH_PATH="${OUT_DIR}/ralph-wiggum-loop.sh.mcpb"
create_mcpb_archive "${STAGE_SH}" "${MCPB_SH_PATH}"
SHA256_SH="$(compute_sha256 "${MCPB_SH_PATH}")"

# -----------------------------------------------------------------------------
# 2. Stage & Build ralph-wiggum-loop.pwsh.mcpb (PowerShell edition: win32)
# -----------------------------------------------------------------------------
STAGE_PWSH="${TEMP_BASE}/pwsh"
mkdir -p "${STAGE_PWSH}"

if command -v jq >/dev/null 2>&1; then
    jq --arg ver "${VERSION}" '.version = $ver' "${REPO_ROOT}/packaging/mcpb/manifest.pwsh.json" > "${STAGE_PWSH}/manifest.json"
else
    cp "${REPO_ROOT}/packaging/mcpb/manifest.pwsh.json" "${STAGE_PWSH}/manifest.json"
fi

render_platform_mcp_json "${MCP_TEMPLATE_PATH}" "${STAGE_PWSH}/mcp.json" "pwsh"

for rel in \
    "bin/ralph-wiggum-loop.ps1" \
    "bin/mcp-sdk.psm1" \
    "bin/script-runner" \
    "bin/script-runner.ps1" \
    "bin/script-runner.cmd" \
    "profiles/lite.json" \
    "profiles/plus.json" \
    "profiles/pro.json" \
    "profiles/super.json" \
    "profiles/ultra.json" \
    "skills/ralph-wiggum-loop/SKILL.md" \
    "skills/ralph-wiggum-loop/references/checklist.md" \
    "skills/ralph-wiggum-loop/references/spec-template.md" \
    "skills/ralph-wiggum-loop/scripts/setup-ralph-loop.ps1" \
    "skills/ralph-wiggum-loop/scripts/start-http-server.ps1" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/hooks.json" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/stop-hook.ps1" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/commands/ralph-loop.md" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/commands/cancel-ralph.md" \
    "io.github.sheldonrobinson.ralph-wiggum-loop/commands/help.md" \
    "plugin.json" \
    "LICENSE" \
    "README.md"
do
    copy_rel_file "${REPO_ROOT}" "${STAGE_PWSH}" "${rel}"
done

MCPB_PWSH_PATH="${OUT_DIR}/ralph-wiggum-loop.pwsh.mcpb"
create_mcpb_archive "${STAGE_PWSH}" "${MCPB_PWSH_PATH}"
SHA256_PWSH="$(compute_sha256 "${MCPB_PWSH_PATH}")"

# -----------------------------------------------------------------------------
# 3. Generate Official MCP Registry server.json with both MCPB packages
# -----------------------------------------------------------------------------
RELEASE_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}"
SERVER_JSON_PATH="${REPO_ROOT}/server.json"

cat > "${SERVER_JSON_PATH}" <<EOF
{
  "\$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
  "name": "io.github.${REPO_OWNER}/${REPO_NAME}",
  "title": "Ralph Wiggum Loop",
  "description": "Autonomous iterative AI development MCP server with spec-driven worker/reviewer SHIP/REVISE loops.",
  "version": "${VERSION}",
  "websiteUrl": "https://${REPO_OWNER}.github.io/${REPO_NAME}",
  "repository": {
    "url": "https://github.com/${REPO_OWNER}/${REPO_NAME}",
    "source": "github"
  },
  "packages": [
    {
      "registryType": "mcpb",
      "identifier": "${RELEASE_BASE}/ralph-wiggum-loop.sh.mcpb",
      "version": "${VERSION}",
      "fileSha256": "${SHA256_SH}",
      "runtimeHint": "sh",
      "transport": {
        "type": "stdio"
      },
      "packageArguments": [
        {
          "type": "named",
          "name": "--stdio",
          "description": "Run the POSIX sh MCP server over standard input/output (stdio)"
        }
      ],
      "environmentVariables": [
        {
          "name": "RALPH_STATE_BASE",
          "description": "Directory path where active Ralph Loop state and iteration history are stored",
          "isRequired": false
        },
        {
          "name": "RALPH_RECIPE_DIR",
          "description": "Directory path containing workflow recipe JSON files",
          "isRequired": false
        }
      ]
    },
    {
      "registryType": "mcpb",
      "identifier": "${RELEASE_BASE}/ralph-wiggum-loop.pwsh.mcpb",
      "version": "${VERSION}",
      "fileSha256": "${SHA256_PWSH}",
      "runtimeHint": "pwsh",
      "transport": {
        "type": "stdio"
      },
      "packageArguments": [
        {
          "type": "named",
          "name": "-Stdio",
          "description": "Run the PowerShell MCP server over standard input/output (stdio)"
        }
      ],
      "environmentVariables": [
        {
          "name": "RALPH_STATE_BASE",
          "description": "Directory path where active Ralph Loop state and iteration history are stored",
          "isRequired": false
        },
        {
          "name": "RALPH_RECIPE_DIR",
          "description": "Directory path containing workflow recipe JSON files",
          "isRequired": false
        }
      ]
    }
  ]
}
EOF

echo "Built Multi-Package MCPB Bundles (v${VERSION}):"
echo "  [1] POSIX sh MCPB (linux, darwin) : ${MCPB_SH_PATH}"
echo "      fileSha256                    : ${SHA256_SH}"
echo "  [2] PowerShell MCPB (win32)       : ${MCPB_PWSH_PATH}"
echo "      fileSha256                    : ${SHA256_PWSH}"
echo "  [3] MCP Registry                  : ${SERVER_JSON_PATH}"

exit 0
