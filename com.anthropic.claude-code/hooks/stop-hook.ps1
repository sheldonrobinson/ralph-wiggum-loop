#Requires -Version 5.1
# Ralph Wiggum Loop Stop Hook (PowerShell)
# Prevents session exit when a Ralph loop is active and completion criteria are not yet met.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HookInput = ''
if ([Console]::IsInputRedirected) {
    $HookInput = [Console]::In.ReadToEnd()
}

$RalphStateFile = if ($env:RALPH_LOCAL_STATE_FILE) { $env:RALPH_LOCAL_STATE_FILE } else { '.agents/ralph-loop.local.md' }
if (-not (Test-Path -LiteralPath $RalphStateFile) -and (Test-Path -LiteralPath '.claude/ralph-loop.local.md')) {
    $RalphStateFile = '.claude/ralph-loop.local.md'
}
$RalphMcpStateBase = if ($env:RALPH_STATE_BASE) {
    $env:RALPH_STATE_BASE
}
elseif ($env:PLUGIN_DATA) {
    Join-Path $env:PLUGIN_DATA 'state'
}
else {
    '.ralph'
}

function Get-LastAssistantText {
    param([string]$HookJson)
    if ([string]::IsNullOrWhiteSpace($HookJson)) { return '' }
    try {
        $hookObj = $HookJson | ConvertFrom-Json -ErrorAction Stop
        $transcriptPath = if ($hookObj.PSObject.Properties['transcript_path']) { [string]$hookObj.transcript_path } else { '' }
        if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath)) {
            return ''
        }
        $lines = Get-Content -LiteralPath $transcriptPath -ErrorAction Stop | Where-Object { $_ -match '"role"\s*:\s*"assistant"' }
        if (-not $lines) { return '' }
        $lastLine = @($lines)[-1]
        $msgObj = $lastLine | ConvertFrom-Json -ErrorAction Stop
        $content = $msgObj.message.content
        if ($content -is [string]) { return $content }
        if ($content -is [System.Collections.IEnumerable]) {
            $texts = foreach ($item in $content) {
                if ($null -ne $item -and $item.PSObject.Properties['type'] -and $item.type -eq 'text') {
                    [string]$item.text
                }
            }
            return ($texts -join "`n")
        }
    }
    catch {}
    return ''
}

if (Test-Path -LiteralPath $RalphStateFile) {
    $rawContent = Get-Content -LiteralPath $RalphStateFile -Raw
    if ($rawContent -match '(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$') {
        $frontmatter = $Matches[1]
        $promptText = $Matches[2].Trim()

        $iteration = if ($frontmatter -match '(?m)^iteration:\s*(\d+)\s*$') { [int]$Matches[1] } else { -1 }
        $maxIterations = if ($frontmatter -match '(?m)^max_iterations:\s*(\d+)\s*$') { [int]$Matches[1] } else { -1 }
        $completionPromise = if ($frontmatter -match '(?m)^completion_promise:\s*"?([^"\r\n]+)"?\s*$') { $Matches[1].Trim() } else { 'null' }

        if ($iteration -lt 0 -or $maxIterations -lt 0 -or [string]::IsNullOrWhiteSpace($promptText)) {
            Remove-Item -LiteralPath $RalphStateFile -Force -ErrorAction SilentlyContinue
            exit 0
        }

        if ($maxIterations -gt 0 -and $iteration -ge $maxIterations) {
            Remove-Item -LiteralPath $RalphStateFile -Force -ErrorAction SilentlyContinue
            exit 0
        }

        $lastOutput = Get-LastAssistantText -HookJson $HookInput
        if ($completionPromise -and $completionPromise -ne 'null' -and $lastOutput) {
            if ($lastOutput.Contains("<promise>$completionPromise</promise>")) {
                Remove-Item -LiteralPath $RalphStateFile -Force -ErrorAction SilentlyContinue
                exit 0
            }
        }

        $nextIteration = $iteration + 1
        $updatedContent = $rawContent -replace '(?m)^iteration:\s*\d+', "iteration: $nextIteration"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $RalphStateFile).Path, $updatedContent, $utf8NoBom)

        $sysMsg = if ($completionPromise -and $completionPromise -ne 'null') {
            "Ralph iteration $nextIteration | To complete: output <promise>$completionPromise</promise> (ONLY when all acceptance criteria and tests pass)"
        }
        else {
            "Ralph iteration $nextIteration | No completion promise set"
        }

        $resp = [ordered]@{
            decision      = 'block'
            reason        = $promptText
            systemMessage = $sysMsg
        } | ConvertTo-Json -Compress
        Write-Output $resp
        exit 0
    }
}

if (Test-Path -LiteralPath $RalphMcpStateBase) {
    $stateFiles = Get-ChildItem -LiteralPath $RalphMcpStateBase -Recurse -Filter 'state.json' -ErrorAction SilentlyContinue
    foreach ($sf in $stateFiles) {
        try {
            $st = Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            $status = [string]$st.status
            $phase = [string]$st.current_phase
            $iter = [int]$st.iteration
            $maxIter = [int]$st.max_iterations
            $sessionId = [string]$st.session_id
            if ($status -in @('in_progress', 'revising') -and $iter -lt $maxIter) {
                $reason = "Ralph Wiggum MCP session '$sessionId' is still active (phase: $phase, status: $status, iteration: $iter/$maxIter). Task: $($st.task_description)"
                if (-not [string]::IsNullOrWhiteSpace([string]$st.review_feedback)) {
                    $reason += " | Latest Reviewer Feedback: $($st.review_feedback)"
                }
                $resp = [ordered]@{
                    decision      = 'block'
                    reason        = $reason
                    systemMessage = "Ralph MCP Loop ($sessionId) iteration $iter/$maxIter [$phase] - Complete review with SHIP to finish."
                } | ConvertTo-Json -Compress
                Write-Output $resp
                exit 0
            }
        }
        catch {}
    }
}

exit 0
