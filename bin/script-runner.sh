#!/usr/bin/env sh
# =============================================================================
# Cross-Platform Polyglot Script Runner (POSIX sh / Bash & PowerShell)
# =============================================================================
# Runs in BOTH POSIX sh/bash and PowerShell (pwsh / powershell.exe), and can
# execute either the .sh or .ps1 version of any script in this plugin.
#
# How the polyglot header works (per cross-platform-command-format-for-sh-and-pwsh.md):
# 1. `sv --% 2>/dev/null ; : '`
#    - In PowerShell: `sv` (Set-Variable) sees `--%` (stop-parsing token) and
#      silently sets variable `--%` (no stdout/stderr); PowerShell then executes
#      the subsequent lines up to `exit $code`.
#    - In POSIX sh (dash/bash/ash): `sv` is not a POSIX special built-in (unlike
#      `set`, which aborts dash with exit code 2 on `--%`), so `sv --% 2>/dev/null`
#      silently fails and `; : '...'` runs a no-op single-quoted literal covering
#      the entire PowerShell section while preserving `$@`.
# 2. `' >/dev/null ; : ' <# '`
#    - In PowerShell: opens a `<# ... #>` block comment hiding all POSIX sh syntax.
#    - In POSIX sh/bash: closes the first `: '...'` and opens a second `: '...'`
#      that consumes `<# `, allowing the POSIX sh section to run cleanly.
# =============================================================================
sv --% 2>/dev/null ; : '
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RunnerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $RunnerDir "..")).Path }
$env:PLUGIN_ROOT = $PluginRoot

function Resolve-TargetScripts {
    param([string]$TargetName)
    if ([string]::IsNullOrWhiteSpace($TargetName)) {
        $TargetName = "ralph-wiggum-loop"
    }
    $stripped = $TargetName -replace "\.(ps1|sh)$", ""
    $candidates = @(
        (Join-Path $PluginRoot "bin\$stripped"),
        (Join-Path $PluginRoot ".agents\skills\ralph-wiggum-loop\scripts\$stripped"),
        (Join-Path $PluginRoot "skills\ralph-wiggum-loop\scripts\$stripped"),
        (Join-Path $PluginRoot "io.github.sheldonrobinson.ralph-wiggum-loop\hooks\$stripped"),
        (Join-Path (Get-Location).Path $stripped)
    )
    if ([System.IO.Path]::IsPathRooted($stripped)) {
        $candidates = @($stripped) + $candidates
    }
    foreach ($base in $candidates) {
        $psPath = "$base.ps1"
        $shPath = "$base.sh"
        if ((Test-Path -LiteralPath $psPath) -or (Test-Path -LiteralPath $shPath)) {
            return [PSCustomObject]@{
                Base   = $base
                PsPath = if (Test-Path -LiteralPath $psPath) { (Resolve-Path -LiteralPath $psPath).Path } else { $null }
                ShPath = if (Test-Path -LiteralPath $shPath) { (Resolve-Path -LiteralPath $shPath).Path } else { $null }
            }
        }
    }
    return $null
}

$ForcedShell = ""
$TargetScript = ""
$ForwardArgs = New-Object System.Collections.Generic.List[string]

$idx = 0
while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    if ($ForwardArgs.Count -eq 0 -and [string]::IsNullOrEmpty($TargetScript)) {
        if ($arg -in @("--use-sh", "--sh", "--bash")) {
            $ForcedShell = "sh"
            $idx++
            continue
        }
        if ($arg -in @("--use-pwsh", "--pwsh", "--ps1", "--powershell")) {
            $ForcedShell = "pwsh"
            $idx++
            continue
        }
        if ($arg -eq "--runner-help") {
            Write-Output @"
Cross-Platform Polyglot Script Runner (POSIX sh / Bash & PowerShell)

USAGE:
  ./bin/script-runner.sh [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]
  pwsh -NoProfile -ExecutionPolicy Bypass -File ./bin/script-runner.ps1 [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]

TARGETS (auto-resolved to .ps1 or .sh):
  ralph-wiggum-loop   (default) Main MCP server & CLI loop runner (bin/ralph-wiggum-loop.{ps1,sh})
  setup-ralph-loop    In-session Stop-hook setup (.agents/skills/ralph-wiggum-loop/scripts/setup-ralph-loop.{ps1,sh})
  start-http-server   Streamable HTTP service manager (.agents/skills/ralph-wiggum-loop/scripts/start-http-server.{ps1,sh})
  stop-hook           Session Stop hook (io.github.sheldonrobinson.ralph-wiggum-loop/hooks/stop-hook.{ps1,sh})
  <path/to/script>    Any custom script path (with or without .ps1 / .sh extension)
"@
            exit 0
        }
        if (-not $arg.StartsWith("-")) {
            $probe = Resolve-TargetScripts -TargetName $arg
            if ($null -ne $probe) {
                $TargetScript = $arg
                $idx++
                continue
            }
        }
        $TargetScript = "ralph-wiggum-loop"
    }
    $ForwardArgs.Add($arg)
    $idx++
}

if ([string]::IsNullOrEmpty($TargetScript)) {
    $TargetScript = "ralph-wiggum-loop"
}

$resolved = Resolve-TargetScripts -TargetName $TargetScript
if ($null -eq $resolved) {
    [Console]::Error.WriteLine("script-runner: Could not find .ps1 or .sh script for target: $TargetScript")
    exit 1
}

$useWindowsPs = $true
if ($ForcedShell -eq "sh") {
    $useWindowsPs = $false
} elseif ($ForcedShell -eq "pwsh") {
    $useWindowsPs = $true
} else {
    $isWin = ($env:OS -eq "Windows_NT") -or ([System.Environment]::OSVersion.Platform -eq "Win32NT")
    if ($isWin -and $null -ne $resolved.PsPath) {
        $useWindowsPs = $true
    } elseif ($null -ne $resolved.ShPath -and -not $isWin) {
        $useWindowsPs = $false
    } elseif ($null -ne $resolved.PsPath) {
        $useWindowsPs = $true
    } else {
        $useWindowsPs = $false
    }
}

$fwdArray = $ForwardArgs.ToArray()
$pipedInput = @($input)

if ($useWindowsPs -and $null -ne $resolved.PsPath) {
    if ($pipedInput.Count -gt 0) {
        $pipedInput | & $resolved.PsPath @fwdArray
    } else {
        & $resolved.PsPath @fwdArray
    }
    $code = if ((Test-Path Variable:\LASTEXITCODE) -and ($null -ne $global:LASTEXITCODE)) { [int]$global:LASTEXITCODE } else { 0 }
    [System.Console]::Out.Flush()
    exit $code
} elseif ($null -ne $resolved.ShPath) {
    $bashCmd = $null
    if (Test-Path "C:\Program Files\Git\bin\bash.exe") {
        $bashCmd = "C:\Program Files\Git\bin\bash.exe"
    } elseif (Get-Command bash -ErrorAction SilentlyContinue) {
        $bashCmd = (Get-Command bash).Source
    } elseif (Get-Command sh -ErrorAction SilentlyContinue) {
        $bashCmd = (Get-Command sh).Source
    } else {
        [Console]::Error.WriteLine("script-runner: Neither bash nor sh found to execute $($resolved.ShPath)")
        exit 1
    }
    if ($pipedInput.Count -gt 0) {
        $pipedInput | & $bashCmd $resolved.ShPath @fwdArray
    } else {
        & $bashCmd $resolved.ShPath @fwdArray
    }
    $code = if ((Test-Path Variable:\LASTEXITCODE) -and ($null -ne $global:LASTEXITCODE)) { [int]$global:LASTEXITCODE } else { 0 }
    [System.Console]::Out.Flush()
    exit $code
} else {
    [Console]::Error.WriteLine("script-runner: No runnable script variant found for $TargetScript")
    exit 1
}
' >/dev/null ; : ' <# '

set -eu

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "${RUNNER_DIR}/.." && pwd)}"
export PLUGIN_ROOT

resolve_target_base() {
    target_name="${1:-ralph-wiggum-loop}"
    stripped="${target_name%.sh}"
    stripped="${stripped%.ps1}"

    for candidate in \
        "${PLUGIN_ROOT}/bin/${stripped}" \
        "${PLUGIN_ROOT}/.agents/skills/ralph-wiggum-loop/scripts/${stripped}" \
        "${PLUGIN_ROOT}/skills/ralph-wiggum-loop/scripts/${stripped}" \
        "${PLUGIN_ROOT}/io.github.sheldonrobinson.ralph-wiggum-loop/hooks/${stripped}" \
        "${stripped}"
    do
        if [ -f "${candidate}.sh" ] || [ -f "${candidate}.ps1" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

FORCED_SHELL=""
TARGET_SCRIPT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --use-sh|--sh|--bash)
            FORCED_SHELL="sh"
            shift
            ;;
        --use-pwsh|--pwsh|--ps1|--powershell)
            FORCED_SHELL="pwsh"
            shift
            ;;
        --runner-help)
            cat << 'HELP_EOF'
Cross-Platform Polyglot Script Runner (POSIX sh / Bash & PowerShell)

USAGE:
  ./bin/script-runner.sh [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]
  pwsh -NoProfile -ExecutionPolicy Bypass -File ./bin/script-runner.ps1 [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]

TARGETS (auto-resolved to .sh or .ps1):
  ralph-wiggum-loop   (default) Main MCP server & CLI loop runner (bin/ralph-wiggum-loop.{sh,ps1})
  setup-ralph-loop    In-session Stop-hook setup (.agents/skills/ralph-wiggum-loop/scripts/setup-ralph-loop.{sh,ps1})
  start-http-server   Streamable HTTP service manager (.agents/skills/ralph-wiggum-loop/scripts/start-http-server.{sh,ps1})
  stop-hook           Session Stop hook (io.github.sheldonrobinson.ralph-wiggum-loop/hooks/stop-hook.{sh,ps1})
  <path/to/script>    Any custom script path (with or without .sh / .ps1 extension)
HELP_EOF
            exit 0
            ;;
        -*)
            break
            ;;
        *)
            if resolve_target_base "$1" >/dev/null 2>&1; then
                TARGET_SCRIPT="$1"
                shift
            fi
            break
            ;;
    esac
done

if [ -z "${TARGET_SCRIPT}" ]; then
    TARGET_SCRIPT="ralph-wiggum-loop"
fi

BASE_PATH="$(resolve_target_base "${TARGET_SCRIPT}" || true)"
if [ -z "${BASE_PATH}" ]; then
    echo "script-runner: Could not find .sh or .ps1 script for target: ${TARGET_SCRIPT}" >&2
    exit 1
fi

SH_PATH="${BASE_PATH}.sh"
PS_PATH="${BASE_PATH}.ps1"

USE_SH="true"
if [ "${FORCED_SHELL}" = "pwsh" ]; then
    USE_SH="false"
elif [ "${FORCED_SHELL}" = "sh" ]; then
    USE_SH="true"
else
    case "$(uname -s 2>/dev/null || echo Unknown)" in
        MINGW*|MSYS*|CYGWIN*)
            # In Git Bash / MSYS on Windows, default to .sh when invoked via sh/bash unless .sh is missing
            if [ -f "${SH_PATH}" ]; then
                USE_SH="true"
            else
                USE_SH="false"
            fi
            ;;
        *)
            if [ -f "${SH_PATH}" ]; then
                USE_SH="true"
            else
                USE_SH="false"
            fi
            ;;
    esac
fi

if [ "${USE_SH}" = "true" ] && [ -f "${SH_PATH}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "${SH_PATH}" "$@"
    else
        exec sh "${SH_PATH}" "$@"
    fi
elif [ -f "${PS_PATH}" ]; then
    if command -v pwsh >/dev/null 2>&1; then
        exec pwsh -NoProfile -ExecutionPolicy Bypass -File "${PS_PATH}" "$@"
    elif command -v powershell.exe >/dev/null 2>&1; then
        exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${PS_PATH}" "$@"
    else
        echo "script-runner: Neither pwsh nor powershell.exe found to execute ${PS_PATH}" >&2
        exit 1
    fi
else
    echo "script-runner: No runnable script variant found for ${TARGET_SCRIPT}" >&2
    exit 1
fi
#>
