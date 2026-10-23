#Requires -Version 5.1
# Ralph Wiggum Loop Stop Hook (PowerShell - Agent-Harness Agnostic)
# Prevents session exit when a Ralph loop is active and completion criteria are not yet met.
# Supports:
#   1. In-session state file (.agents/ralph-loop.local.md) with <promise>...</promise>
#   2. Multi-model MCP session state (.ralph/<session>/state.json or ${PLUGIN_DATA}/state/<session>/state.json)
#   3. Any agent harness hook payload (inline message/output/response/content fields, transcript_path JSON/JSONL, or plain text stdin)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pipedLines = @($input)
$HookInput = if ($pipedLines.Count -gt 0) {
    $pipedLines -join "`n"
}
elseif ([Console]::IsInputRedirected) {
    [Console]::In.ReadToEnd()
}
else {
    ''
}

$RalphStateFile = if ($env:RALPH_LOCAL_STATE_FILE) { $env:RALPH_LOCAL_STATE_FILE } else { '.agents/ralph-loop.local.md' }
$RalphMcpStateBase = if ($env:RALPH_STATE_BASE) {
    $env:RALPH_STATE_BASE
}
elseif ($env:PLUGIN_DATA) {
    Join-Path $env:PLUGIN_DATA 'state'
}
else {
    '.ralph'
}

function Convert-ContentToText {
    param($ContentValue)
    if ($null -eq $ContentValue) { return '' }
    if ($ContentValue -is [string]) { return $ContentValue }
    if ($ContentValue -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $ContentValue) {
            if ($null -eq $item) { continue }
            if ($item -is [string]) { $item }
            elseif ($item.PSObject.Properties['text']) { [string]$item.text }
            elseif ($item.PSObject.Properties['content']) { [string]$item.content }
        }
        return ($parts -join "`n")
    }
    if ($ContentValue.PSObject.Properties['text']) { return [string]$ContentValue.text }
    if ($ContentValue.PSObject.Properties['content']) { return (Convert-ContentToText $ContentValue.content) }
    return ''
}

function Get-LastAssistantText {
    param([string]$HookPayload)
    if ([string]::IsNullOrWhiteSpace($HookPayload)) {
        if ($env:RALPH_LAST_OUTPUT) { return [string]$env:RALPH_LAST_OUTPUT }
        return ''
    }
    try {
        $hookObj = $HookPayload | ConvertFrom-Json -ErrorAction Stop
        if ($hookObj -is [string]) { return $hookObj }

        foreach ($field in @('last_assistant_message', 'assistant_message', 'output', 'response', 'text', 'content', 'message')) {
            if ($hookObj.PSObject.Properties[$field] -and $null -ne $hookObj.$field) {
                $extracted = Convert-ContentToText $hookObj.$field
                if (-not [string]::IsNullOrWhiteSpace($extracted)) {
                    return $extracted
                }
            }
        }

        $transcriptPath = ''
        foreach ($pathField in @('transcript_path', 'transcriptPath', 'session_log', 'log_path')) {
            if ($hookObj.PSObject.Properties[$pathField] -and $hookObj.$pathField) {
                $transcriptPath = [string]$hookObj.$pathField
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path -LiteralPath $transcriptPath)) {
            $lines = Get-Content -LiteralPath $transcriptPath -ErrorAction Stop | Where-Object { $_ -match '"role"\s*:\s*"assistant"' }
            if ($lines) {
                $lastLine = @($lines)[-1]
                $msgObj = $lastLine | ConvertFrom-Json -ErrorAction Stop
                if ($msgObj.PSObject.Properties['message']) {
                    return (Convert-ContentToText $msgObj.message)
                }
                if ($msgObj.PSObject.Properties['content']) {
                    return (Convert-ContentToText $msgObj.content)
                }
            }
            return (Get-Content -LiteralPath $transcriptPath -Raw -ErrorAction SilentlyContinue)
        }
    }
    catch {
        return $HookPayload
    }
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

        $lastOutput = Get-LastAssistantText -HookPayload $HookInput
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
        [System.Console]::Out.WriteLine($resp)
        [System.Console]::Out.Flush()
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
                [System.Console]::Out.WriteLine($resp)
                [System.Console]::Out.Flush()
                exit 0
            }
        }
        catch {}
    }
}

exit 0
