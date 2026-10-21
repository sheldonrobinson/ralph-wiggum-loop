#Requires -Version 5.1
# Ralph Wiggum Loop - In-Session Setup Script (PowerShell)
# Creates state file (.agents/ralph-loop.local.md) for in-session Stop hook loops

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PromptParts = New-Object System.Collections.Generic.List[string]
$MaxIterations = 0
$CompletionPromise = 'DONE'
$StateFile = if ($env:RALPH_LOCAL_STATE_FILE) { $env:RALPH_LOCAL_STATE_FILE } else { '.agents/ralph-loop.local.md' }

$idx = 0
while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    switch ($arg) {
        { $_ -in @('-h', '--help') } {
            Write-Output @"
Ralph Wiggum Loop - Interactive self-referential development loop

USAGE:
  scripts/setup-ralph-loop.ps1 [PROMPT...] [OPTIONS]

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: 0 = unlimited)
  --completion-promise '<text>'  Promise phrase inside <promise>...</promise> (default: DONE)
  -h, --help                     Show this help message
"@
            exit 0
        }
        '--max-iterations' {
            if (($idx + 1) -ge $args.Count -or ([string]$args[$idx + 1] -notmatch '^\d+$')) {
                [Console]::Error.WriteLine('Error: --max-iterations requires a non-negative integer')
                exit 1
            }
            $MaxIterations = [int]$args[$idx + 1]
            $idx += 2
        }
        '--completion-promise' {
            if (($idx + 1) -ge $args.Count -or [string]::IsNullOrWhiteSpace([string]$args[$idx + 1])) {
                [Console]::Error.WriteLine('Error: --completion-promise requires a text argument')
                exit 1
            }
            $CompletionPromise = [string]$args[$idx + 1]
            $idx += 2
        }
        default {
            $PromptParts.Add($arg)
            $idx++
        }
    }
}

$Prompt = ($PromptParts -join ' ').Trim()
if ([string]::IsNullOrWhiteSpace($Prompt)) {
    [Console]::Error.WriteLine('Error: No prompt provided. Usage: setup-ralph-loop.ps1 <PROMPT> [--max-iterations N] [--completion-promise TEXT]')
    exit 1
}

$StateDir = Split-Path -Parent $StateFile
if ($StateDir -and -not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

$PromiseYaml = if ($CompletionPromise -and $CompletionPromise -ne 'null') {
    '"' + ($CompletionPromise -replace '"', '\"') + '"'
} else {
    'null'
}

$StartedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$Content = @"
---
active: true
iteration: 1
max_iterations: $MaxIterations
completion_promise: $PromiseYaml
started_at: "$StartedAt"
---

$Prompt
"@

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$FullStatePath = if ([System.IO.Path]::IsPathRooted($StateFile)) { $StateFile } else { Join-Path (Get-Location).Path $StateFile }
[System.IO.File]::WriteAllText($FullStatePath, $Content, $Utf8NoBom)

$MaxIterDisplay = if ($MaxIterations -gt 0) { $MaxIterations } else { 'unlimited' }
Write-Output @"
Ralph Wiggum loop activated in this session!
- State file: $StateFile
- Iteration: 1
- Max iterations: $MaxIterDisplay
- Completion promise: <promise>$CompletionPromise</promise>
"@
