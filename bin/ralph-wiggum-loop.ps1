<#>
.SYNOPSIS
    ralph-wiggum-loop.ps1 - Ralph Loop Agent Plugin (PowerShell: MCP Server + CLI Orchestration)
    Cross-platform implementation of the Ralph Loop iterative development technique
    Imports generic mcp-sdk.psm1 for shared MCP protocol utilities.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# HELPER: Null-coalescing for PowerShell 5.1+
# =============================================================================
function Coalesce {
    param($Value, $Default)
    if ($null -ne $Value -and $Value -ne '') { return $Value }
    return $Default
}

# =============================================================================
# IMPORT THE GENERIC MCP SDK MODULE
# =============================================================================
if ([string]::IsNullOrEmpty($env:MCP_TRANSPORT) -and -not [string]::IsNullOrEmpty($env:RALPH_TRANSPORT)) {
    $env:MCP_TRANSPORT = $env:RALPH_TRANSPORT
}
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $script:ScriptDir 'mcp-sdk.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Set-McpServerInfo -Name 'ralph-wiggum-loop' -Version '1.1.0'

function JsonToDict {
    param($Json)
    if ($null -eq $Json) { return @{} }
    if ($Json -is [System.Collections.IDictionary]) {
        return $Json
    }
    if ($Json -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Json)) { return @{} }
        $obj = $Json | ConvertFrom-Json
        return ConvertTo-McpHashtable $obj
    }
    if ($Json -is [System.Management.Automation.PSCustomObject]) {
        return ConvertTo-McpHashtable $Json
    }
    return @{ value = $Json }
}

# =============================================================================
# CONFIGURATION (from environment variables with defaults, supporting Agent Plugins PLUGIN_ROOT & PLUGIN_DATA)
# =============================================================================
$script:PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { Split-Path -Parent $script:ScriptDir }
$script:Workspace = if ($env:WORKSPACE) { $env:WORKSPACE } else { (Get-Location).Path }
$script:RalphStateBase = if ($env:RALPH_STATE_BASE) {
    $env:RALPH_STATE_BASE
}
elseif ($env:PLUGIN_DATA) {
    Join-Path $env:PLUGIN_DATA 'state'
}
else {
    Join-Path $script:Workspace '.ralph'
}
$script:RalphRecipeDir = Coalesce $env:RALPH_RECIPE_DIR (Join-Path $script:PluginRoot 'recipes')
$script:SafeCommands = @('ls', 'pwd', 'echo', 'date', 'cat', 'mkdir', 'rm', 'cp', 'mv', 'jq')
$script:CmdTimeout = 30

# Rate limit & retry configuration
$script:MaxRetries = [int](Coalesce $env:RALPH_MAX_RETRIES 3)
$script:InitialBackoff = [int](Coalesce $env:RALPH_INITIAL_BACKOFF 5)
$script:ThrottleDelay = [int](Coalesce $env:RALPH_THROTTLE_DELAY 0)

# Environment variable defaults
$script:WorkerModel = Coalesce $env:RALPH_WORKER_MODEL ''
$script:WorkerProvider = Coalesce $env:RALPH_WORKER_PROVIDER ''
$script:WorkerAgent = Coalesce $env:RALPH_WORKER_AGENT 'goose'
$script:ReviewerModel = Coalesce $env:RALPH_REVIEWER_MODEL ''
$script:ReviewerProvider = Coalesce $env:RALPH_REVIEWER_PROVIDER ''
$script:ReviewerAgent = Coalesce $env:RALPH_REVIEWER_AGENT 'goose'
$script:MaxIterations = [int](Coalesce $env:RALPH_MAX_ITERATIONS 10)
$script:WorkGuidelines = Coalesce $env:RALPH_WORK_GUIDELINES (Join-Path $script:RalphRecipeDir 'ralph-work.yaml')
$script:ReviewGuidelines = Coalesce $env:RALPH_REVIEW_GUIDELINES (Join-Path $script:RalphRecipeDir 'ralph-review.yaml')
$script:MonitorModel = Coalesce $env:RALPH_MONITOR_MODEL ''
$script:MonitorProvider = Coalesce $env:RALPH_MONITOR_PROVIDER (Coalesce $env:RALPH_MONITON_PROVIDER '')
$script:MonitorAgent = Coalesce $env:RALPH_MONITOR_AGENT 'goose'

$script:CurrentProfile = ''
$script:CLITask = ''
$script:CLISessionId = ''

# Profile support via environment variable
if ($env:RALPH_PROFILE -and (Test-Path $env:RALPH_PROFILE)) {
    try {
        $profile = Get-Content $env:RALPH_PROFILE -Raw | ConvertFrom-Json
        if ($profile.workerModel)      { $script:WorkerModel = $profile.workerModel }
        if ($profile.workerProvider)   { $script:WorkerProvider = $profile.workerProvider }
        if ($profile.workerAgent)      { $script:WorkerAgent = $profile.workerAgent }
        if ($profile.reviewerModel)    { $script:ReviewerModel = $profile.reviewerModel }
        if ($profile.reviewerProvider) { $script:ReviewerProvider = $profile.reviewerProvider }
        if ($profile.reviewerAgent)    { $script:ReviewerAgent = $profile.reviewerAgent }
        if ($profile.monitorModel)     { $script:MonitorModel = $profile.monitorModel }
        if ($profile.monitorProvider)  { $script:MonitorProvider = $profile.monitorProvider }
        if ($profile.monitorAgent)     { $script:MonitorAgent = $profile.monitorAgent }
        if ($profile.maxIterations)    { $script:MaxIterations = [int]$profile.maxIterations }
        if ($profile.workGuidelines)   { $script:WorkGuidelines = $profile.workGuidelines }
        if ($profile.reviewGuidelines) { $script:ReviewGuidelines = $profile.reviewGuidelines }
    }
    catch {
        Write-Error "Failed to load profile from '$env:RALPH_PROFILE': $_"
    }
    $script:CurrentProfile = (Split-Path $env:RALPH_PROFILE -Leaf) -replace '\.json$', ''
}

# =============================================================================
# STATE & PROFILE UTILITIES
# =============================================================================
function Get-StateDir {
    param([string]$SessionId = 'default')
    return Join-Path $script:RalphStateBase $SessionId
}

function Get-StateFile {
    param([string]$SessionId = 'default', [string]$FileName)
    return Join-Path (Get-StateDir -SessionId $SessionId) $FileName
}

function Ensure-StateDir {
    param([string]$SessionId = 'default')
    $dir = Get-StateDir -SessionId $SessionId
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Resolve-ProfilePath {
    param([string]$ProfileName)
    $candidates = @(
        (Join-Path (Join-Path $script:PluginRoot 'profiles') "$ProfileName.json"),
        (Join-Path (Join-Path $script:PluginRoot 'profiles') $ProfileName),
        (Join-Path (Join-Path $script:Workspace 'profiles') "$ProfileName.json"),
        (Join-Path (Join-Path $script:Workspace 'profiles') $ProfileName),
        (Join-Path $script:Workspace $ProfileName),
        $ProfileName,
        (Join-Path (Join-Path (Split-Path -Parent $script:ScriptDir) 'profiles') "$ProfileName.json"),
        (Join-Path (Join-Path (Split-Path -Parent $script:ScriptDir) 'profiles') $ProfileName),
        (Join-Path (Join-Path $script:ScriptDir 'profiles') "$ProfileName.json"),
        (Join-Path (Join-Path $script:ScriptDir 'profiles') $ProfileName)
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c -PathType Leaf)) {
            return (Resolve-Path $c).Path
        }
    }
    return $null
}

function Test-RateLimitError {
    param([string]$Output)
    if ($Output -match '(?i)(rate_limit|rate limit|429|quota_exceeded|quota exceeded|resource_exhausted|resource exhausted|too many requests|overloaded|throttled)') {
        return $true
    }
    return $false
}

function Apply-RateThrottling {
    param([int]$ThrottleDelay = 0)
    if ($ThrottleDelay -gt 0) {
        Start-Sleep -Seconds $ThrottleDelay
    }
}

function Invoke-LlmWithRetry {
    param(
        [string]$RoleName,
        [string]$SessionId,
        [scriptblock]$ScriptBlock
    )
    $maxRetries = $script:MaxRetries
    $initialBackoff = $script:InitialBackoff
    $throttleDelay = $script:ThrottleDelay
    if ($SessionId -and $SessionId -ne 'default') {
        $configStr = Get-Config -SessionId $SessionId
        if ($configStr) {
            $config = JsonToDict $configStr
            $maxRetries = [int](Coalesce $config['maxRetries'] 3)
            $initialBackoff = [int](Coalesce $config['initialBackoff'] 5)
            $throttleDelay = [int](Coalesce $config['throttleDelay'] 0)
        }
    }
    Apply-RateThrottling -ThrottleDelay $throttleDelay
    $attempt = 1
    $backoff = $initialBackoff
    $maxAttempts = $maxRetries + 1
    $output = ''

    while ($attempt -le $maxAttempts) {
        $output = & $ScriptBlock
        if ($output -and (-not (Test-RateLimitError -Output $output))) {
            return $output
        }

        if ((Test-RateLimitError -Output $output) -or (-not $output)) {
            if ($attempt -lt $maxAttempts) {
                Write-Host "[WARN] [$RoleName] Rate limit / resource constraint detected on attempt $attempt/$maxRetries. Retrying in ${backoff}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $backoff
                $backoff = $backoff * 2
                $attempt++
                continue
            }
            else {
                Write-Host "[ERROR] [$RoleName] Rate limit / quota error persisted after $maxRetries retries." -ForegroundColor Red
                if (Test-RateLimitError -Output $output) {
                    return "RATE_LIMIT_EXCEEDED: $output"
                }
                return $null
            }
        }
        return $output
    }
    return $null
}

# =============================================================================
# CONFIG, TASK, WORK, REVIEW & STATUS MANAGEMENT
# =============================================================================
function Set-Config {
    param(
        [string]$SessionId,
        [string]$WorkerModel,
        [string]$WorkerProvider,
        [string]$ReviewerModel,
        [string]$ReviewerProvider,
        [int]$MaxIterations = 10,
        [bool]$CrossModelEnforced = $true,
        [string]$WorkerAgent = 'goose',
        [string]$ReviewerAgent = 'goose',
        [string]$WorkGuidelines = '',
        [string]$ReviewGuidelines = '',
        [string]$MonitorModel = '',
        [string]$MonitorProvider = '',
        [string]$MonitorAgent = 'goose',
        [int]$InitialBackoff = 5,
        [int]$ThrottleDelay = 0,
        [int]$MaxRetries = 3
    )
    Ensure-StateDir -SessionId $SessionId
    $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'
    $configObj = [PSCustomObject]@{
        workerModel              = [string]$WorkerModel
        workerProvider           = [string]$WorkerProvider
        workerAgent              = [string]$WorkerAgent
        reviewerModel            = [string]$ReviewerModel
        reviewerProvider         = [string]$ReviewerProvider
        reviewerAgent            = [string]$ReviewerAgent
        monitorModel             = [string]$MonitorModel
        monitorProvider          = [string]$MonitorProvider
        monitorAgent             = [string]$MonitorAgent
        maxIterations            = $MaxIterations
        initialBackoff           = $InitialBackoff
        throttleDelay            = $ThrottleDelay
        maxRetries               = $MaxRetries
        crossModelReviewEnforced = $CrossModelEnforced
        workGuidelines           = [string]$WorkGuidelines
        reviewGuidelines         = [string]$ReviewGuidelines
        configuredAt             = (Get-Date).ToString('o')
    }
    $json = ConvertTo-Json -InputObject $configObj -Depth 10
    $json | Set-Content -Path $configFile -Encoding UTF8
}

function Get-Config {
    param([string]$SessionId = 'default')
    $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'
    if (Test-Path $configFile) { return Get-Content $configFile -Raw -Encoding UTF8 }
    return ''
}

function Test-CrossModel {
    param([string]$SessionId = 'default')
    $config = Get-Config -SessionId $SessionId
    if (-not $config) { return '{"valid":true}' }
    $configObj = $config | ConvertFrom-Json
    $enforced = if ($null -ne $configObj.crossModelReviewEnforced) { [bool]$configObj.crossModelReviewEnforced } else { $true }
    if (-not $enforced) { return '{"valid":true}' }
    $workerModel = Coalesce $configObj.workerModel ''
    $workerProvider = Coalesce $configObj.workerProvider ''
    $reviewerModel = Coalesce $configObj.reviewerModel ''
    $reviewerProvider = Coalesce $configObj.reviewerProvider ''
    if ($workerModel -and $reviewerModel -and $workerModel -eq $reviewerModel -and $workerProvider -eq $reviewerProvider) {
        return '{"valid":false,"warning":"Worker and reviewer are the same model/provider. Cross-model review requires different models."}'
    }
    return '{"valid":true}'
}

function Set-Task {
    param([string]$SessionId, [string]$Task)
    Ensure-StateDir -SessionId $SessionId
    $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'
    $taskObj = [PSCustomObject]@{
        task      = [string]$Task
        createdAt = (Get-Date).ToString('o')
    }
    $json = ConvertTo-Json -InputObject $taskObj -Depth 10
    $json | Set-Content -Path $taskFile -Encoding UTF8
    $blockedFile = Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'
    if (Test-Path $blockedFile) { Remove-Item $blockedFile -Force }
}

function Get-Task {
    param([string]$SessionId = 'default')
    $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'
    if (Test-Path $taskFile) { return Get-Content $taskFile -Raw -Encoding UTF8 }
    return ''
}

function Set-Work {
    param([string]$SessionId, [string]$Work, [string]$Summary, [int]$Iteration)
    Ensure-StateDir -SessionId $SessionId
    $workFile = Get-StateFile -SessionId $SessionId -FileName 'work.json'
    $workObj = [PSCustomObject]@{
        work        = [string]$Work
        summary     = [string]$Summary
        submittedAt = (Get-Date).ToString('o')
        iteration   = $Iteration
    }
    $json = ConvertTo-Json -InputObject $workObj -Depth 10
    $json | Set-Content -Path $workFile -Encoding UTF8
    $completeFile = Get-StateFile -SessionId $SessionId -FileName 'work-complete.txt'
    '{"ok":true}' | Set-Content -Path $completeFile -Encoding UTF8

    $histDir = Join-Path (Join-Path (Get-StateDir -SessionId $SessionId) 'history') "iteration_$Iteration"
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }
    Copy-Item -Path $workFile -Destination (Join-Path $histDir 'work.json') -Force
    $workOutFile = Get-StateFile -SessionId $SessionId -FileName 'work.out'
    if (Test-Path $workOutFile) { Copy-Item -Path $workOutFile -Destination (Join-Path $histDir 'work.out') -Force }
}

function Get-Work {
    param([string]$SessionId = 'default')
    $workFile = Get-StateFile -SessionId $SessionId -FileName 'work.json'
    if (Test-Path $workFile) { return Get-Content $workFile -Raw -Encoding UTF8 }
    return ''
}

function Set-Review {
    param([string]$SessionId, [string]$Decision, [string]$Feedback, [int]$Iteration)
    Ensure-StateDir -SessionId $SessionId
    $reviewFile = Get-StateFile -SessionId $SessionId -FileName 'review.json'
    $reviewObj = [PSCustomObject]@{
        decision   = [string]$Decision
        feedback   = [string]$Feedback
        reviewedAt = (Get-Date).ToString('o')
        iteration  = $Iteration
    }
    $json = ConvertTo-Json -InputObject $reviewObj -Depth 10
    $json | Set-Content -Path $reviewFile -Encoding UTF8

    $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'
    $resultObj = [PSCustomObject]@{ decision = [string]$Decision }
    (ConvertTo-Json -InputObject $resultObj -Compress -Depth 10) | Set-Content -Path $resultFile -Encoding UTF8

    $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'
    $feedbackObj = [PSCustomObject]@{ feedback = [string]$Feedback }
    (ConvertTo-Json -InputObject $feedbackObj -Compress -Depth 10) | Set-Content -Path $feedbackFile -Encoding UTF8

    $histDir = Join-Path (Join-Path (Get-StateDir -SessionId $SessionId) 'history') "iteration_$Iteration"
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }
    Copy-Item -Path $reviewFile -Destination (Join-Path $histDir 'review.json') -Force
    $reviewOutFile = Get-StateFile -SessionId $SessionId -FileName 'review.out'
    if (Test-Path $reviewOutFile) { Copy-Item -Path $reviewOutFile -Destination (Join-Path $histDir 'review.out') -Force }

    if ($Decision -eq 'REVISE') { Cleanup-ForNextIteration -SessionId $SessionId }
}

function Get-Review {
    param([string]$SessionId = 'default')
    $reviewFile = Get-StateFile -SessionId $SessionId -FileName 'review.json'
    if (Test-Path $reviewFile) { return Get-Content $reviewFile -Raw -Encoding UTF8 }
    return ''
}

function Get-ReviewResult {
    param([string]$SessionId = 'default')
    $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'
    if (Test-Path $resultFile) {
        $content = Get-Content $resultFile -Raw -Encoding UTF8
        return ($content | ConvertFrom-Json).decision
    }
    return ''
}

function Get-Feedback {
    param([string]$SessionId = 'default')
    $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'
    if (Test-Path $feedbackFile) {
        $content = Get-Content $feedbackFile -Raw -Encoding UTF8
        return ($content | ConvertFrom-Json).feedback
    }
    return ''
}

function Get-Status {
    param([string]$SessionId = 'default', [int]$MaxIterations = 10)
    $task = Get-Task -SessionId $SessionId
    $work = Get-Work -SessionId $SessionId
    $reviewResult = Get-ReviewResult -SessionId $SessionId
    $feedback = Get-Feedback -SessionId $SessionId
    $config = Get-Config -SessionId $SessionId
    $blocked = Test-Path (Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md')
    $crossModelValidation = JsonToDict (Test-CrossModel -SessionId $SessionId)
    $phase = 'WORK'
    $status = 'running'
    $currentIteration = 1
    if ($blocked) {
        $phase = 'BLOCKED'
        $status = 'blocked'
    }
    elseif ($reviewResult -eq 'SHIP') {
        $phase = 'COMPLETE'
        $status = 'shipped'
        if ($work) {
            $workObj = JsonToDict $work
            $currentIteration = [int](Coalesce $workObj['iteration'] 1)
        }
    }
    elseif ($reviewResult -eq 'REVISE') {
        $phase = 'WORK'
        $status = 'revised'
        if ($work) {
            $workObj = JsonToDict $work
            $currentIteration = [int](Coalesce $workObj['iteration'] 1) + 1
        }
    }
    elseif ($work) {
        $phase = 'REVIEW'
        $status = 'running'
        $workObj = JsonToDict $work
        $currentIteration = [int](Coalesce $workObj['iteration'] 1)
    }
    if ($currentIteration -gt $MaxIterations -and $status -eq 'running') {
        $status = 'max_iterations_reached'
        $phase = 'COMPLETE'
    }
    $taskText = ''
    $createdAt = ''
    if ($task) {
        $taskObj = JsonToDict $task
        $taskText = Coalesce $taskObj['task'] ''
        $createdAt = Coalesce $taskObj['createdAt'] ''
    }
    $workSummary = ''
    if ($work) {
        $workObj = JsonToDict $work
        $workSummary = Coalesce $workObj['summary'] ''
    }
    $workerModel = ''
    $workerProvider = ''
    $workerAgent = ''
    $reviewerModel = ''
    $reviewerProvider = ''
    $reviewerAgent = ''
    $monitorModel = ''
    $monitorProvider = ''
    $monitorAgent = ''
    $crossModelEnforced = $true
    $crossModelValid = $true
    $crossModelWarning = ''
    $workGuidelines = ''
    $reviewGuidelines = ''
    if ($config) {
        $configObj = JsonToDict $config
        $workerModel = Coalesce $configObj['workerModel'] ''
        $workerProvider = Coalesce $configObj['workerProvider'] ''
        $workerAgent = Coalesce $configObj['workerAgent'] ''
        $reviewerModel = Coalesce $configObj['reviewerModel'] ''
        $reviewerProvider = Coalesce $configObj['reviewerProvider'] ''
        $reviewerAgent = Coalesce $configObj['reviewerAgent'] ''
        $monitorModel = Coalesce $configObj['monitorModel'] ''
        $monitorProvider = Coalesce $configObj['monitorProvider'] ''
        $monitorAgent = Coalesce $configObj['monitorAgent'] ''
        if ($null -ne $configObj['crossModelReviewEnforced']) {
            $crossModelEnforced = [bool]$configObj['crossModelReviewEnforced']
        }
        if ($null -ne $crossModelValidation['valid']) {
            $crossModelValid = [bool]$crossModelValidation['valid']
        }
        $crossModelWarning = Coalesce $crossModelValidation['warning'] ''
        $workGuidelines = Coalesce $configObj['workGuidelines'] ''
        $reviewGuidelines = Coalesce $configObj['reviewGuidelines'] ''
    }
    return [ordered]@{
        sessionId                = $SessionId
        currentIteration         = $currentIteration
        maxIterations            = $MaxIterations
        phase                    = $phase
        status                   = $status
        task                     = if ($taskText) { $taskText } else { $null }
        lastWorkSummary          = if ($workSummary) { $workSummary } else { $null }
        lastFeedback             = if ($feedback) { $feedback } else { $null }
        createdAt                = if ($createdAt) { $createdAt } else { $null }
        updatedAt                = (Get-Date).ToString('o')
        workerModel              = if ($workerModel) { $workerModel } else { $null }
        workerProvider           = if ($workerProvider) { $workerProvider } else { $null }
        workerAgent              = if ($workerAgent) { $workerAgent } else { $null }
        reviewerModel            = if ($reviewerModel) { $reviewerModel } else { $null }
        reviewerProvider         = if ($reviewerProvider) { $reviewerProvider } else { $null }
        reviewerAgent            = if ($reviewerAgent) { $reviewerAgent } else { $null }
        monitorModel             = if ($monitorModel) { $monitorModel } else { $null }
        monitorProvider          = if ($monitorProvider) { $monitorProvider } else { $null }
        monitorAgent             = if ($monitorAgent) { $monitorAgent } else { $null }
        crossModelReviewEnforced = $crossModelEnforced
        crossModelReviewValid    = $crossModelValid
        crossModelReviewWarning  = if ($crossModelWarning) { $crossModelWarning } else { $null }
        workGuidelines           = if ($workGuidelines) { $workGuidelines } else { $null }
        reviewGuidelines         = if ($reviewGuidelines) { $reviewGuidelines } else { $null }
    }
}

function Cleanup-ForNextIteration {
    param([string]$SessionId)
    $files = @('work-complete.txt', 'review-result.txt', 'review-feedback.txt', 'work.json', 'review.json', 'work.out', 'review.out')
    foreach ($file in $files) {
        $path = Get-StateFile -SessionId $SessionId -FileName $file
        if (Test-Path $path -PathType Leaf) { Remove-Item $path -Force }
    }
}

function Reset-Session {
    param([string]$SessionId)
    $stateDir = Get-StateDir -SessionId $SessionId
    if (Test-Path $stateDir) { Remove-Item $stateDir -Recurse -Force }
}

function Block-Iteration {
    param([string]$SessionId, [string]$Reason)
    Ensure-StateDir -SessionId $SessionId
    $blockedFile = Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'
    $Reason | Set-Content -Path $blockedFile -Encoding UTF8
}

# =============================================================================
# ORCHESTRATION HELPERS
# =============================================================================
function Call-WorkerLlm {
    param([string]$Task, [string]$Feedback, [int]$Iteration, [string]$SessionId, [string]$WorkerModel, [string]$WorkerProvider, [string]$WorkerAgent, [string]$WorkGuidelines, [bool]$IsExisting = $false)
    $prompt = "You are the WORKER in a Ralph Loop iteration $Iteration.`n`nTask: $Task`n"
    if ($Feedback) { $prompt += "Previous feedback from reviewer: $Feedback`nPlease revise your work based on this feedback.`n" }
    $prompt += "Provide your complete work output and a brief summary.`nOutput format:`nWORK:`n[your complete work here]`n`nSUMMARY:`n[brief summary of what you did]`n"

    return Invoke-LlmWithRetry -RoleName 'WORKER' -SessionId $SessionId -ScriptBlock {
        switch ($WorkerAgent) {
            'anthropic' { return $prompt | claude --model $WorkerModel --print 2>$null }
            'claude'    { return $prompt | claude --model $WorkerModel --print 2>$null }
            'openai'    { return $prompt | openai chat --model $WorkerModel --no-stream 2>$null }
            'google'    { return $prompt | gemini --model $WorkerModel --format=text 2>$null }
            'gemini'    { return $prompt | gemini --model $WorkerModel --format=text 2>$null }
            'copilot'   { return $prompt | copilot -p --allow-all-tools 2>$null }
            'goose' {
                $gooseParams = @("task=$Task", "sessionId=$SessionId")
                if ($Feedback) { $gooseParams += "feedback=$Feedback" }
                $gooseArgs = @('run')
                if ($WorkGuidelines -and (Test-Path $WorkGuidelines)) {
                    $gooseArgs += '--recipe', $WorkGuidelines
                }
                $gooseArgs += '--params', ($gooseParams -join ' ')
                if ($SessionId) {
                    if ($IsExisting) { $gooseArgs += '--resume' }
                    $gooseArgs += '--name', $SessionId
                }
                else {
                    $gooseArgs += '--no-session'
                }
                $gooseArgs += '--text', $prompt
                $env:GOOSE_MODEL = $WorkerModel
                $env:GOOSE_PROVIDER = $WorkerProvider
                $stateDir = Get-StateDir -SessionId $SessionId
                Ensure-StateDir -SessionId $SessionId
                Push-Location $stateDir
                try {
                    goose $gooseArgs 1>work.out 2>$null
                    if (Test-Path work.out) { return Get-Content work.out -Raw }
                    return $null
                }
                finally {
                    Pop-Location
                }
            }
            default { Write-Host "Error: Unknown agent $WorkerAgent" -ForegroundColor Red; return $null }
        }
    }
}

function Call-ReviewerLlm {
    param([string]$Task, [string]$Work, [string]$Summary, [int]$Iteration, [string]$SessionId, [string]$ReviewerModel, [string]$ReviewerProvider, [string]$ReviewerAgent, [string]$ReviewGuidelines, [bool]$IsExisting = $false)
    $prompt = "You are the REVIEWER in a Ralph Loop iteration $Iteration.`n`nOriginal Task: $Task`n`nWorker's Work:`n$Work`n`nWorker's Summary: $Summary`n`nReview this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).`nIf REVISE, provide specific, actionable feedback for the worker.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [your feedback, or empty if SHIP]`n"

    return Invoke-LlmWithRetry -RoleName 'REVIEWER' -SessionId $SessionId -ScriptBlock {
        switch ($ReviewerAgent) {
            'anthropic' { return $prompt | claude --model $ReviewerModel --print 2>$null }
            'claude'    { return $prompt | claude --model $ReviewerModel --print 2>$null }
            'openai'    { return $prompt | openai chat --model $ReviewerModel --no-stream 2>$null }
            'google'    { return $prompt | gemini --model $ReviewerModel --format=text 2>$null }
            'gemini'    { return $prompt | gemini --model $ReviewerModel --format=text 2>$null }
            'copilot'   { return $prompt | copilot -p --allow-all-tools 2>$null }
            'goose' {
                $gooseParams = @("task=$Task", "work=$Work", "summary=$Summary", "sessionId=$SessionId")
                $gooseArgs = @('run')
                if ($ReviewGuidelines -and (Test-Path $ReviewGuidelines)) {
                    $gooseArgs += '--recipe', $ReviewGuidelines
                }
                $gooseArgs += '--params', ($gooseParams -join ' ')
                if ($SessionId) {
                    if ($IsExisting) { $gooseArgs += '--resume' }
                    $gooseArgs += '--name', $SessionId
                }
                else {
                    $gooseArgs += '--no-session'
                }
                $gooseArgs += '--text', $prompt
                $env:GOOSE_MODEL = $ReviewerModel
                $env:GOOSE_PROVIDER = $ReviewerProvider
                $stateDir = Get-StateDir -SessionId $SessionId
                Ensure-StateDir -SessionId $SessionId
                Push-Location $stateDir
                try {
                    goose $gooseArgs 1>review.out 2>$null
                    if (Test-Path review.out) { return Get-Content review.out -Raw }
                    return $null
                }
                finally {
                    Pop-Location
                }
            }
            default { Write-Host "Error: Unknown agent $ReviewerAgent" -ForegroundColor Red; return $null }
        }
    }
}

function Call-MonitorLlm {
    param([string]$Prompt, [string]$MonitorModel, [string]$MonitorProvider, [string]$MonitorAgent, [string]$SessionId = '')
    if (-not $MonitorModel) { $MonitorModel = $script:MonitorModel }
    if (-not $MonitorProvider) { $MonitorProvider = $script:MonitorProvider }
    if (-not $MonitorAgent) { $MonitorAgent = $script:MonitorAgent }
    if (-not $MonitorModel) {
        $config = JsonToDict (Get-Config -SessionId $SessionId)
        if ($config) { $MonitorModel = Coalesce $config['monitorModel'] '' }
        if (-not $MonitorModel) { $MonitorModel = $script:WorkerModel }
    }
    if (-not $MonitorProvider) {
        $config = JsonToDict (Get-Config -SessionId $SessionId)
        if ($config) { $MonitorProvider = Coalesce $config['monitorProvider'] '' }
        if (-not $MonitorProvider) { $MonitorProvider = $script:WorkerProvider }
    }
    if (-not $MonitorAgent) {
        $config = JsonToDict (Get-Config -SessionId $SessionId)
        if ($config) { $MonitorAgent = Coalesce $config['monitorAgent'] '' }
        if (-not $MonitorAgent) { $MonitorAgent = $script:WorkerAgent }
    }

    return Invoke-LlmWithRetry -RoleName 'MONITOR' -SessionId $SessionId -ScriptBlock {
        switch ($MonitorAgent) {
            'anthropic' { return $Prompt | claude --model $MonitorModel --print 2>$null }
            'claude'    { return $Prompt | claude --model $MonitorModel --print 2>$null }
            'openai'    { return $Prompt | openai chat --model $MonitorModel --no-stream 2>$null }
            'google'    { return $Prompt | gemini --model $MonitorModel --format=text 2>$null }
            'gemini'    { return $Prompt | gemini --model $MonitorModel --format=text 2>$null }
            'goose' {
                $env:GOOSE_MODEL = $MonitorModel
                $env:GOOSE_PROVIDER = $MonitorProvider
                $tempFile = Join-Path $env:TEMP "ralph-monitor-$([System.IO.Path]::GetRandomFileName()).txt"
                try {
                    $Prompt | Out-File -FilePath $tempFile -Encoding UTF8
                    return goose run --no-session -i $tempFile 2>$null
                }
                finally {
                    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
                }
            }
            default { return $Prompt | openai chat --model $MonitorModel --no-stream 2>$null }
        }
    }
}

function Parse-WorkerOutput {
    param([string]$Output, [string]$MonitorModel = '', [string]$MonitorProvider = '', [string]$MonitorAgent = '', [string]$OutputFile = '', [string]$SessionId = '')
    $work = ''; $summary = ''
    $mWork = [regex]::Match($Output, '(?s)WORK:(.*?)SUMMARY:')
    if ($mWork.Success) { $work = $mWork.Groups[1].Value.Trim() }
    $mSummary = [regex]::Match($Output, '(?s)SUMMARY:(.*)')
    if ($mSummary.Success) { $summary = $mSummary.Groups[1].Value.Trim() }
    if (-not $work -or -not $summary) {
        Write-Host "  Regex parsing failed for worker output, consulting Monitor LLM..." -ForegroundColor Yellow
        if ($MonitorAgent -eq 'goose' -and $OutputFile -and (Test-Path $OutputFile)) {
            $monitorPrompt = "Read the file at '$OutputFile' then extract the WORK and SUMMARY sections from its content.`n`nIf the agent created or modified files, include the file paths and key content in WORK.`nSummarize what was accomplished in SUMMARY.`n`nOutput format:`nWORK:`n[extracted work content]`n`nSUMMARY:`n[one-line summary]"
        }
        else {
            $monitorPrompt = "Extract the WORK and SUMMARY sections from the following raw agent output.`n`nIf the agent created or modified files, include the file paths and key content in WORK.`nSummarize what was accomplished in SUMMARY.`n`nOutput format:`nWORK:`n[extracted work content]`n`nSUMMARY:`n[one-line summary]`n`n---`n$Output"
        }
        $monitorResponse = Call-MonitorLlm -Prompt $monitorPrompt -MonitorModel $MonitorModel -MonitorProvider $MonitorProvider -MonitorAgent $MonitorAgent -SessionId $SessionId
        if ($monitorResponse) {
            $mWork2 = [regex]::Match($monitorResponse, '(?s)WORK:(.*?)SUMMARY:')
            if ($mWork2.Success) { $work = $mWork2.Groups[1].Value.Trim() }
            $mSummary2 = [regex]::Match($monitorResponse, '(?s)SUMMARY:(.*)')
            if ($mSummary2.Success) { $summary = $mSummary2.Groups[1].Value.Trim() }
        }
        if ($work -or $summary) { Write-Host "  Monitor LLM parsed successfully." -ForegroundColor Green }
        else { Write-Host "  Monitor LLM also could not parse the output." -ForegroundColor Red }
    }
    return @{ work = $work; summary = $summary }
}

function Parse-ReviewerOutput {
    param([string]$Output, [string]$MonitorModel = '', [string]$MonitorProvider = '', [string]$MonitorAgent = '', [string]$OutputFile = '', [string]$SessionId = '')
    $decision = ''; $feedback = ''
    $mDecision = [regex]::Match($Output, '(?i)DECISION:\s*(SHIP|REVISE)')
    if ($mDecision.Success) { $decision = $mDecision.Groups[1].Value.ToUpper() }
    $mFeedback = [regex]::Match($Output, '(?s)FEEDBACK:\s*(.*)')
    if ($mFeedback.Success) { $feedback = $mFeedback.Groups[1].Value.Trim() }
    if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') {
        Write-Host "  Regex parsing failed for reviewer output, consulting Monitor LLM..." -ForegroundColor Yellow
        if ($MonitorAgent -eq 'goose' -and $OutputFile -and (Test-Path $OutputFile)) {
            $monitorPrompt = "Read the file at '$OutputFile' then extract the DECISION (SHIP or REVISE) and FEEDBACK from its content.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [the review feedback]"
        }
        else {
            $monitorPrompt = "Extract the DECISION (SHIP or REVISE) and FEEDBACK from the following raw agent output.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [the review feedback]`n`n---`n$Output"
        }
        $monitorResponse = Call-MonitorLlm -Prompt $monitorPrompt -MonitorModel $MonitorModel -MonitorProvider $MonitorProvider -MonitorAgent $MonitorAgent -SessionId $SessionId
        if ($monitorResponse) {
            $mDecision2 = [regex]::Match($monitorResponse, '(?i)DECISION:\s*(SHIP|REVISE)')
            if ($mDecision2.Success) { $decision = $mDecision2.Groups[1].Value.ToUpper() }
            $mFeedback2 = [regex]::Match($monitorResponse, '(?s)FEEDBACK:\s*(.*)')
            if ($mFeedback2.Success) { $feedback = $mFeedback2.Groups[1].Value.Trim() }
        }
        if ($decision -eq 'SHIP' -or $decision -eq 'REVISE') { Write-Host "  Monitor LLM parsed successfully." -ForegroundColor Green }
        else { Write-Host "  Monitor LLM also could not parse the output." -ForegroundColor Red }
    }
    return @{ decision = $decision; feedback = $feedback }
}

# =============================================================================
# ADAPTIVE PROFILE SWITCHING
# =============================================================================
$script:AdaptiveOrders = @{
    'quality'  = @{ resource = @('ultra','super','pro','plus','lite'); quality = @('lite','plus','pro','super','ultra'); start = 'ultra' }
    'price'    = @{ resource = @('ultra','super','pro','plus','lite'); quality = @('lite','plus','pro','super','ultra'); start = 'lite' }
    'balanced' = @{ resource = @('pro','plus','lite'); quality = @('pro','super','ultra'); start = 'pro' }
}

function Test-ResourceTrigger {
    param([string]$WorkerOutput, [string]$ReviewerOutput, [string]$Feedback)
    $regex = '(?i)(rate_limit|rate limit|429|quota_exceeded|quota exceeded|resource_exhausted|resource exhausted|too many requests|overloaded|throttled|out of memory|insufficient (quota|resources))'
    return ($WorkerOutput -and $WorkerOutput -match $regex) -or
           ($ReviewerOutput -and $ReviewerOutput -match $regex) -or
           ($Feedback -and $Feedback -match '(?i)(resource|memory|cpu|quota|limit)')
}

function Test-QualityTrigger {
    param([string]$WorkerOutput, [string]$ReviewerOutput, [string]$Feedback)
    foreach ($text in @($WorkerOutput, $ReviewerOutput, $Feedback)) {
        if (-not $text) { continue }
        if ($text -match '(?i)(low quality|poor quality|nonsensical|incoherent|garbled|repetitive|repeating itself|lorem ipsum|placeholder)') {
            return $true
        }
        $words = [regex]::Matches($text, '\b\w{8,}\b') | ForEach-Object { $_.Value.ToLower() }
        $counts = @{}
        foreach ($w in $words) { $counts[$w] = [int]$counts[$w] + 1 }
        foreach ($k in $counts.Keys) { if ($counts[$k] -ge 6) { return $true } }
    }
    return $false
}

function Get-AdaptiveProfileSwitch {
    param([string]$Strategy, [string]$Trigger, [string]$CurrentProfile)
    if (-not $script:AdaptiveOrders.ContainsKey($Strategy)) { return $null }
    $order = $script:AdaptiveOrders[$Strategy][$Trigger]
    if (-not $order) { return $null }
    if (-not $CurrentProfile) { return $order[0] }
    $idx = [Array]::IndexOf($order, $CurrentProfile)
    if ($idx -eq -1) { return $order[0] }
    return $order[($idx + 1) % $order.Count]
}

function Apply-Profile {
    param([string]$SessionId, [string]$ProfileName)
    $profilePath = Resolve-ProfilePath -ProfileName $ProfileName
    if (-not $profilePath) {
        Write-Host "[ERROR] Profile file not found: $ProfileName" -ForegroundColor Red
        return
    }
    Ensure-StateDir -SessionId $SessionId
    $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
    $props = @($profile.PSObject.Properties.Name)
    $config = [PSCustomObject]@{
        workerModel              = if ($props -contains 'workerModel') { [string]$profile.workerModel } else { '' }
        workerProvider           = if ($props -contains 'workerProvider') { [string]$profile.workerProvider } else { '' }
        workerAgent              = if ($props -contains 'workerAgent' -and $profile.workerAgent) { [string]$profile.workerAgent } else { 'goose' }
        reviewerModel            = if ($props -contains 'reviewerModel') { [string]$profile.reviewerModel } else { '' }
        reviewerProvider         = if ($props -contains 'reviewerProvider') { [string]$profile.reviewerProvider } else { '' }
        reviewerAgent            = if ($props -contains 'reviewerAgent' -and $profile.reviewerAgent) { [string]$profile.reviewerAgent } else { 'goose' }
        monitorModel             = if ($props -contains 'monitorModel') { [string]$profile.monitorModel } else { '' }
        monitorProvider          = if ($props -contains 'monitorProvider') { [string]$profile.monitorProvider } else { '' }
        monitorAgent             = if ($props -contains 'monitorAgent' -and $profile.monitorAgent) { [string]$profile.monitorAgent } else { 'goose' }
        maxIterations            = if ($props -contains 'maxIterations' -and $profile.maxIterations) { [int]$profile.maxIterations } else { 10 }
        initialBackoff           = if ($props -contains 'initialBackoff' -and $profile.initialBackoff) { [int]$profile.initialBackoff } else { 5 }
        throttleDelay            = if ($props -contains 'throttleDelay' -and $null -ne $profile.throttleDelay) { [int]$profile.throttleDelay } else { 0 }
        maxRetries               = if ($props -contains 'maxRetries' -and $profile.maxRetries) { [int]$profile.maxRetries } else { 3 }
        crossModelReviewEnforced = $true
        workGuidelines           = if ($props -contains 'workGuidelines') { [string]$profile.workGuidelines } else { '' }
        reviewGuidelines         = if ($props -contains 'reviewGuidelines') { [string]$profile.reviewGuidelines } else { '' }
        configuredAt             = (Get-Date).ToString('o')
    }
    $json = ConvertTo-Json -InputObject $config -Depth 10
    $json | Set-Content -Path (Get-StateFile -SessionId $SessionId -FileName 'config.json') -Encoding UTF8
    Write-Host "[ADAPTIVE] Applied profile: $ProfileName" -ForegroundColor Green
}

function Switch-AdaptiveProfile {
    param([string]$SessionId, [string]$NewProfile, [string]$OldProfile = '')
    Write-Host "[ADAPTIVE] Switching profile from '$OldProfile' to '$NewProfile'" -ForegroundColor Cyan
    Apply-Profile -SessionId $SessionId -ProfileName $NewProfile
    $config = JsonToDict (Get-Config -SessionId $SessionId)
    return @{
        workerModel      = Coalesce $config['workerModel'] ''
        workerProvider   = Coalesce $config['workerProvider'] ''
        workerAgent      = Coalesce $config['workerAgent'] 'goose'
        reviewerModel    = Coalesce $config['reviewerModel'] ''
        reviewerProvider = Coalesce $config['reviewerProvider'] ''
        reviewerAgent    = Coalesce $config['reviewerAgent'] 'goose'
        monitorModel     = Coalesce $config['monitorModel'] ''
        monitorProvider  = Coalesce $config['monitorProvider'] ''
        monitorAgent     = Coalesce $config['monitorAgent'] 'goose'
        maxIterations    = [int](Coalesce $config['maxIterations'] 10)
        initialBackoff   = [int](Coalesce $config['initialBackoff'] 5)
        throttleDelay    = [int](Coalesce $config['throttleDelay'] 0)
        maxRetries       = [int](Coalesce $config['maxRetries'] 3)
    }
}

# =============================================================================
# CLI ORCHESTRATION MODE
# =============================================================================
function Run-Cli {
    $cliArgs = $script:ScriptArgs
    if ($cliArgs -contains '-h' -or $cliArgs -contains '--help') {
        Write-Host "ralph-wiggum-loop.ps1 - PowerShell Implementation"
        Write-Host "Usage: .\ralph-wiggum-loop.ps1 [options] `"task description`" or .\ralph-wiggum-loop.ps1 [options] path/to/task.md"
        Write-Host ""
        Write-Host "Modes:"
        Write-Host "  MCP Server  : .\ralph-wiggum-loop.ps1 [--stdio | --http | --streamable-http] [--port PORT]"
        Write-Host "  CLI Mode    : .\ralph-wiggum-loop.ps1 [options] `"task description`" [--profile pro]"
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  --profile PROFILE            Quality profile (lite, plus, pro, super, ultra)"
        Write-Host "  --worker-model MODEL         Worker model (default: `$env:RALPH_WORKER_MODEL)"
        Write-Host "  --worker-provider PROVIDER   Worker provider (default: `$env:RALPH_WORKER_PROVIDER)"
        Write-Host "  --worker-agent AGENT         Worker agent (default: `$env:RALPH_WORKER_AGENT)"
        Write-Host "  --reviewer-model MODEL       Reviewer model (default: `$env:RALPH_REVIEWER_MODEL)"
        Write-Host "  --reviewer-provider PROVIDER Reviewer provider (default: `$env:RALPH_REVIEWER_PROVIDER)"
        Write-Host "  --reviewer-agent AGENT       Reviewer agent (default: `$env:RALPH_REVIEWER_AGENT)"
        Write-Host "  --monitor-model MODEL        Monitor model (default: `$env:RALPH_MONITOR_MODEL)"
        Write-Host "  --monitor-provider PROVIDER  Monitor provider (default: `$env:RALPH_MONITOR_PROVIDER)"
        Write-Host "  --monitor-agent AGENT        Monitor agent (default: `$env:RALPH_MONITOR_AGENT)"
        Write-Host "  --max-iterations N           Max iterations, -1 for infinite (default: `$env:RALPH_MAX_ITERATIONS)"
        Write-Host "  --work-guidelines FILE       Work guidelines/recipe file"
        Write-Host "  --review-guidelines FILE     Review guidelines/recipe file"
        Write-Host "  --session-id ID              Session ID (default: auto-generated)"
        Write-Host "  --max-retries N              Max retry attempts for rate limits"
        Write-Host "  --initial-backoff N          Initial backoff seconds for retries"
        Write-Host "  --throttle-delay N           Delay between requests in seconds"
        Write-Host "  --enable-adaptive            Enable adaptive profile switching"
        Write-Host "  --adaptive-strategy STRATEGY Adaptive strategy: quality, price, or balanced (default: balanced)"
        Write-Host "  --workspace DIR              Workspace directory (default: current working directory)"
        Write-Host "  -h, --help                   Show this help message"
        exit 0
    }

    $workerModel = $script:WorkerModel
    $workerProvider = $script:WorkerProvider
    $workerAgent = $script:WorkerAgent
    $reviewerModel = $script:ReviewerModel
    $reviewerProvider = $script:ReviewerProvider
    $reviewerAgent = $script:ReviewerAgent
    $maxIterations = $script:MaxIterations
    $workGuidelines = $script:WorkGuidelines
    $reviewGuidelines = $script:ReviewGuidelines
    $monitorModel = $script:MonitorModel
    $monitorProvider = $script:MonitorProvider
    $monitorAgent = $script:MonitorAgent
    $maxRetries = $script:MaxRetries
    $initialBackoff = $script:InitialBackoff
    $throttleDelay = $script:ThrottleDelay
    $enableAdaptive = $false
    $adaptiveStrategy = 'balanced'
    $currentProfile = Coalesce $script:CurrentProfile ''
    $cliProfile = ''
    $workspace = $script:Workspace

    $positionalArgs = @()
    for ($i = 0; $i -lt $cliArgs.Count; $i++) {
        switch ($cliArgs[$i]) {
            '--worker-model'      { $workerModel = $cliArgs[$i+1]; $i++ }
            '--worker-provider'   { $workerProvider = $cliArgs[$i+1]; $i++ }
            '--worker-agent'      { $workerAgent = $cliArgs[$i+1]; $i++ }
            '--reviewer-model'    { $reviewerModel = $cliArgs[$i+1]; $i++ }
            '--reviewer-provider' { $reviewerProvider = $cliArgs[$i+1]; $i++ }
            '--reviewer-agent'    { $reviewerAgent = $cliArgs[$i+1]; $i++ }
            '--max-iterations'    { $maxIterations = [int]$cliArgs[$i+1]; $i++ }
            '--work-guidelines'   { $workGuidelines = $cliArgs[$i+1]; $i++ }
            '--review-guidelines' { $reviewGuidelines = $cliArgs[$i+1]; $i++ }
            '--session-id'        { $script:CLISessionId = $cliArgs[$i+1]; $i++ }
            '--monitor-model'     { $monitorModel = $cliArgs[$i+1]; $i++ }
            '--monitor-provider'  { $monitorProvider = $cliArgs[$i+1]; $i++ }
            '--monitor-agent'     { $monitorAgent = $cliArgs[$i+1]; $i++ }
            '--max-retries'       { $maxRetries = [int]$cliArgs[$i+1]; $i++ }
            '--initial-backoff'   { $initialBackoff = [int]$cliArgs[$i+1]; $i++ }
            '--throttle-delay'    { $throttleDelay = [int]$cliArgs[$i+1]; $i++ }
            '--enable-adaptive'   { $enableAdaptive = $true }
            '--adaptive-strategy' { $adaptiveStrategy = $cliArgs[$i+1]; $i++ }
            '--profile'           { $cliProfile = $cliArgs[$i+1]; $i++ }
            '--workspace'         { $workspace = $cliArgs[$i+1]; $i++ }
            default               { $positionalArgs += $cliArgs[$i] }
        }
    }

    if ($workspace) {
        $resolvedWs = Resolve-Path -Path $workspace -ErrorAction SilentlyContinue
        $script:Workspace = if ($resolvedWs) { $resolvedWs.Path } else { $workspace }
        $script:RalphStateBase = Join-Path $script:Workspace '.ralph'
    }

    $taskInput = if ($positionalArgs.Count -gt 0) { $positionalArgs[-1] } else { '' }
    $taskFilePath = $null
    if ($taskInput) {
        if (Test-Path $taskInput -PathType Leaf) { $taskFilePath = $taskInput }
        elseif (Test-Path (Join-Path $script:Workspace $taskInput) -PathType Leaf) { $taskFilePath = (Join-Path $script:Workspace $taskInput) }
    }
    $task = if ($taskFilePath) { Get-Content $taskFilePath -Raw } else { $taskInput }
    if (-not $task) {
        Write-Host "Error: No task provided" -ForegroundColor Red
        exit 1
    }

    $script:MaxRetries = $maxRetries
    $script:InitialBackoff = $initialBackoff
    $script:ThrottleDelay = $throttleDelay

    if ($enableAdaptive) {
        if (-not $script:AdaptiveOrders.ContainsKey($adaptiveStrategy)) {
            $adaptiveStrategy = 'balanced'
        }
        if (-not $currentProfile) {
            $currentProfile = $script:AdaptiveOrders[$adaptiveStrategy]['start']
        }
        $profilePath = Resolve-ProfilePath -ProfileName $currentProfile
        if ($profilePath) {
            $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
            $props = @($profile.PSObject.Properties.Name)
            if (-not $workerModel -and ($props -contains 'workerModel'))         { $workerModel = $profile.workerModel }
            if (-not $workerProvider -and ($props -contains 'workerProvider'))   { $workerProvider = $profile.workerProvider }
            if (-not $workerAgent -and ($props -contains 'workerAgent'))         { $workerAgent = $profile.workerAgent }
            if (-not $reviewerModel -and ($props -contains 'reviewerModel'))     { $reviewerModel = $profile.reviewerModel }
            if (-not $reviewerProvider -and ($props -contains 'reviewerProvider')) { $reviewerProvider = $profile.reviewerProvider }
            if (-not $reviewerAgent -and ($props -contains 'reviewerAgent'))     { $reviewerAgent = $profile.reviewerAgent }
            if (-not $monitorModel -and ($props -contains 'monitorModel'))       { $monitorModel = $profile.monitorModel }
            if (-not $monitorProvider -and ($props -contains 'monitorProvider')) { $monitorProvider = $profile.monitorProvider }
            if (-not $monitorAgent -and ($props -contains 'monitorAgent'))       { $monitorAgent = $profile.monitorAgent }
        }
    }

    if ($cliProfile) {
        $profilePath = Resolve-ProfilePath -ProfileName $cliProfile
        if ($profilePath) {
            $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
            $props = @($profile.PSObject.Properties.Name)
            if (-not $workerModel -and ($props -contains 'workerModel'))           { $workerModel = $profile.workerModel }
            if (-not $workerProvider -and ($props -contains 'workerProvider'))     { $workerProvider = $profile.workerProvider }
            if ($props -contains 'workerAgent' -and $profile.workerAgent)          { $workerAgent = $profile.workerAgent }
            if (-not $reviewerModel -and ($props -contains 'reviewerModel'))       { $reviewerModel = $profile.reviewerModel }
            if (-not $reviewerProvider -and ($props -contains 'reviewerProvider')) { $reviewerProvider = $profile.reviewerProvider }
            if ($props -contains 'reviewerAgent' -and $profile.reviewerAgent)      { $reviewerAgent = $profile.reviewerAgent }
            if (-not $monitorModel -and ($props -contains 'monitorModel'))         { $monitorModel = $profile.monitorModel }
            if (-not $monitorProvider -and ($props -contains 'monitorProvider'))   { $monitorProvider = $profile.monitorProvider }
            if ($props -contains 'monitorAgent' -and $profile.monitorAgent)        { $monitorAgent = $profile.monitorAgent }
            if ($props -contains 'maxIterations' -and $profile.maxIterations)      { $maxIterations = [int]$profile.maxIterations }
            if ($props -contains 'initialBackoff' -and $profile.initialBackoff)    { $initialBackoff = [int]$profile.initialBackoff }
            if ($props -contains 'throttleDelay' -and $null -ne $profile.throttleDelay) { $throttleDelay = [int]$profile.throttleDelay }
            if ($props -contains 'maxRetries' -and $profile.maxRetries)            { $maxRetries = [int]$profile.maxRetries }
            $currentProfile = (Split-Path $profilePath -Leaf) -replace '\.json$', ''
            Write-Host "[PROFILE] Loaded profile: $currentProfile" -ForegroundColor Cyan
        }
        else {
            Write-Host "[ERROR] Profile not found: $cliProfile" -ForegroundColor Red
            exit 1
        }
    }

    if (-not $workerModel -or -not $workerProvider -or -not $reviewerModel -or -not $reviewerProvider) {
        if ([Console]::IsInputRedirected -or (-not [Environment]::UserInteractive)) {
            [Console]::Error.WriteLine("[ERROR] Missing required worker/reviewer model or provider in non-interactive mode. Use --profile <lite|plus|pro|super|ultra> or pass --worker-model, --worker-provider, --reviewer-model, --reviewer-provider.")
            exit 1
        }
    }
    if (-not $workerModel)      { Write-Host -NoNewline "Worker model: "; $workerModel = Read-Host; if (-not $workerModel) { exit 1 } }
    if (-not $workerProvider)   { Write-Host -NoNewline "Worker provider (anthropic/openai/google/goose/copilot): "; $workerProvider = Read-Host; if (-not $workerProvider) { exit 1 } }
    if (-not $workerAgent)      { Write-Host -NoNewline "Worker agent (goose/claude/openai/gemini/copilot): "; $workerAgent = Read-Host; if (-not $workerAgent) { exit 1 } }
    if (-not $reviewerModel)    { Write-Host -NoNewline "Reviewer model (different from worker): "; $reviewerModel = Read-Host; if (-not $reviewerModel) { exit 1 } }
    if (-not $reviewerProvider) { Write-Host -NoNewline "Reviewer provider (anthropic/openai/google/goose/copilot): "; $reviewerProvider = Read-Host; if (-not $reviewerProvider) { exit 1 } }
    if (-not $reviewerAgent)    { Write-Host -NoNewline "Reviewer agent (goose/claude/openai/gemini/copilot): "; $reviewerAgent = Read-Host; if (-not $reviewerAgent) { exit 1 } }

    if ($workerModel -eq $reviewerModel -and $workerProvider -eq $reviewerProvider) {
        if ([Console]::IsInputRedirected -or (-not [Environment]::UserInteractive)) {
            [Console]::Error.WriteLine("[ERROR] Worker and reviewer cannot be the same model/provider in non-interactive mode.")
            exit 1
        }
        Write-Host "Warning: Worker and reviewer are the same model/provider." -ForegroundColor Yellow
        Write-Host -NoNewline "Continue? [y/N]: "
        $confirm = Read-Host
        if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }
    }

    $sessionId = Coalesce $script:CLISessionId "ralph-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Host "Session: $sessionId"
    Write-Host "Task: $task"
    Write-Host "Worker: $workerModel ($workerProvider) via $workerAgent"
    Write-Host "Reviewer: $reviewerModel ($reviewerProvider) via $reviewerAgent"
    if ($monitorModel) {
        Write-Host "Monitor: $monitorModel ($monitorProvider) via $monitorAgent"
    }
    if ($maxIterations -eq -1) { Write-Host "Max Iterations: unlimited" } else { Write-Host "Max Iterations: $maxIterations" }
    Write-Host ""

    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $true -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -InitialBackoff $initialBackoff -ThrottleDelay $throttleDelay -MaxRetries $maxRetries

    $feedback = ''
    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }

    for ($i = 1; $i -le $maxIter; $i++) {
        $iteration = $i
        Write-Host "======================================================================"
        Write-Host "  Iteration $iteration / $maxIterations"
        Write-Host "======================================================================"

        Write-Host ">> WORK PHASE"
        Write-Host "Worker: $workerModel ($workerProvider) via $workerAgent"

        $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $iteration -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))

        if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations; $initialBackoff = $sw.initialBackoff; $throttleDelay = $sw.throttleDelay; $maxRetries = $sw.maxRetries
                    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }
                    $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $iteration -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))
                }
            }
            if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
                Write-Host "[ERROR] WORK PHASE FAILED - Rate limit, quota error, or no output from worker" -ForegroundColor Red
                Block-Iteration -SessionId $sessionId -Reason 'WORK PHASE FAILED - Rate limit or quota error from worker LLM'
                exit 1
            }
        }

        $workOutFile = Get-StateFile -SessionId $sessionId -FileName 'work.out'
        $workerOutput | Out-File -FilePath $workOutFile -Encoding UTF8

        $parsed = Parse-WorkerOutput -Output $workerOutput -OutputFile $workOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $work = $parsed.work; $summary = $parsed.summary
        if (-not $work -or -not $summary) { Write-Host "[ERROR] WORK PHASE FAILED - Could not parse output" -ForegroundColor Red; exit 1 }

        Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $iteration
        Write-Host "Work submitted. Summary: $summary"
        Write-Host ""

        Write-Host ">> REVIEW PHASE"
        Write-Host "Reviewer: $reviewerModel ($reviewerProvider) via $reviewerAgent"

        $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $iteration -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))

        if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations; $initialBackoff = $sw.initialBackoff; $throttleDelay = $sw.throttleDelay; $maxRetries = $sw.maxRetries
                    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }
                    $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $iteration -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))
                }
            }
            if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
                Write-Host "[ERROR] REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer" -ForegroundColor Red
                Block-Iteration -SessionId $sessionId -Reason 'REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM'
                exit 1
            }
        }

        $reviewOutFile = Get-StateFile -SessionId $sessionId -FileName 'review.out'
        $reviewerOutput | Out-File -FilePath $reviewOutFile -Encoding UTF8

        $parsed = Parse-ReviewerOutput -Output $reviewerOutput -OutputFile $reviewOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $decision = $parsed.decision; $feedback = $parsed.feedback
        if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') { Write-Host "[ERROR] REVIEW PHASE FAILED - Invalid decision: $decision" -ForegroundColor Red; exit 1 }

        Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $iteration

        if ($decision -eq 'SHIP') {
            Write-Host ""
            Write-Host "======================================================================"
            Write-Host "  ** SHIPPED after $iteration iteration(s)" -ForegroundColor Green
            Write-Host "======================================================================"
            Write-Host "Session: $sessionId"
            Write-Host "Complete: $(Get-Date)"
            exit 0
        }
        else {
            Write-Host ""
            Write-Host ">> REVISE - Feedback for next iteration:" -ForegroundColor Yellow
            Write-Host $feedback
            Write-Host ""

            if ($enableAdaptive) {
                $trigger = ''
                if (Test-QualityTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'quality' }
                elseif (Test-ResourceTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'resource' }
                $newProfile = if ($trigger) { Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger $trigger -CurrentProfile $currentProfile } else { $null }
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations; $initialBackoff = $sw.initialBackoff; $throttleDelay = $sw.throttleDelay; $maxRetries = $sw.maxRetries
                    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }
                }
            }
        }
    }

    Write-Host "[ERROR] Max iterations ($maxIterations) reached" -ForegroundColor Red
    exit 1
}

# =============================================================================
# TOOL HANDLERS (MCP Server mode via mcp-sdk.psm1)
# =============================================================================
function Handle-Initialize {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $task = Coalesce $paramsObj['task'] ''
    $maxIterations = [int](Coalesce (Coalesce $paramsObj['maxIterations'] $paramsObj['max_iterations']) 10)
    $initialBackoff = [int](Coalesce (Coalesce $paramsObj['initialBackoff'] $paramsObj['initial_backoff']) 5)
    $throttleDelay = [int](Coalesce (Coalesce $paramsObj['throttleDelay'] $paramsObj['throttle_delay']) 0)
    $maxRetries = [int](Coalesce (Coalesce $paramsObj['maxRetries'] $paramsObj['max_retries']) 3)
    $workerModel = Coalesce (Coalesce $paramsObj['workerModel'] $paramsObj['worker_model']) ''
    $workerProvider = Coalesce (Coalesce $paramsObj['workerProvider'] $paramsObj['worker_provider']) ''
    $workerAgent = Coalesce (Coalesce $paramsObj['workerAgent'] $paramsObj['worker_agent']) 'goose'
    $reviewerModel = Coalesce (Coalesce $paramsObj['reviewerModel'] $paramsObj['reviewer_model']) ''
    $reviewerProvider = Coalesce (Coalesce $paramsObj['reviewerProvider'] $paramsObj['reviewer_provider']) ''
    $reviewerAgent = Coalesce (Coalesce $paramsObj['reviewerAgent'] $paramsObj['reviewer_agent']) 'goose'
    $monitorModel = Coalesce (Coalesce $paramsObj['monitorModel'] $paramsObj['monitor_model']) $script:MonitorModel
    $monitorProvider = Coalesce (Coalesce $paramsObj['monitorProvider'] $paramsObj['monitor_provider']) $script:MonitorProvider
    $monitorAgent = Coalesce (Coalesce $paramsObj['monitorAgent'] $paramsObj['monitor_agent']) $script:MonitorAgent
    $crossModelRaw = Coalesce $paramsObj['crossModelReviewEnforced'] $paramsObj['cross_model_review_enforced']
    $crossModelEnforced = if ($null -ne $crossModelRaw -and $crossModelRaw -ne '') { [bool]$crossModelRaw } else { $true }
    $workGuidelines = Coalesce (Coalesce $paramsObj['workGuidelines'] $paramsObj['work_guidelines']) ''
    $reviewGuidelines = Coalesce (Coalesce $paramsObj['reviewGuidelines'] $paramsObj['review_guidelines']) ''

    if (-not $task) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'Task is required')
    }

    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $crossModelEnforced -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -InitialBackoff $initialBackoff -ThrottleDelay $throttleDelay -MaxRetries $maxRetries
    $validation = JsonToDict (Test-CrossModel -SessionId $sessionId)
    $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations
    $result = [ordered]@{
        success          = $true
        message          = "Ralph Loop initialized for session `"$sessionId`""
        status           = $status
        crossModelReview = [ordered]@{
            enforced = $crossModelEnforced
            valid    = if ($null -ne $validation['valid']) { [bool]$validation['valid'] } else { $true }
            warning  = Coalesce $validation['warning'] ''
        }
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-GetTask {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $task = Get-Task -SessionId $sessionId
    if (-not $task) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'No task found. Initialize the session first with ralph_loop_initialize.')
    }
    $taskObj = JsonToDict $task
    $result = [ordered]@{
        success   = $true
        task      = Coalesce $taskObj['task'] ''
        createdAt = Coalesce $taskObj['createdAt'] ''
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-SubmitWork {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $work = Coalesce $paramsObj['work'] ''
    $summary = Coalesce $paramsObj['summary'] ''
    $iteration = $paramsObj['iteration']
    if (-not $work -or -not $summary -or -not $iteration) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'work, summary, and iteration are required')
    }
    Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration ([int]$iteration)
    $status = Get-Status -SessionId $sessionId
    $result = [ordered]@{
        success = $true
        message = "Work submitted for iteration $iteration"
        status  = $status
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-GetWork {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $work = Get-Work -SessionId $sessionId
    if (-not $work) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'No work submitted yet. Worker must submit work first.')
    }
    $workObj = JsonToDict $work
    $result = [ordered]@{
        success     = $true
        work        = Coalesce $workObj['work'] ''
        summary     = Coalesce $workObj['summary'] ''
        iteration   = [int](Coalesce $workObj['iteration'] 0)
        submittedAt = Coalesce $workObj['submittedAt'] ''
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-SubmitReview {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $decision = Coalesce $paramsObj['decision'] ''
    $feedback = Coalesce $paramsObj['feedback'] ''
    $iteration = $paramsObj['iteration']
    if (-not $decision -or -not $iteration) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'decision and iteration are required')
    }
    if ($decision -eq 'REVISE' -and -not $feedback) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'Feedback is required when decision is REVISE')
    }
    Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration ([int]$iteration)
    $status = Get-Status -SessionId $sessionId
    $result = [ordered]@{
        success  = $true
        message  = "Review submitted: $decision"
        decision = $decision
        feedback = $feedback
        status   = $status
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-GetFeedback {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $reviewResult = Get-ReviewResult -SessionId $sessionId
    $feedback = Get-Feedback -SessionId $sessionId
    $status = Get-Status -SessionId $sessionId
    if (-not $reviewResult) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'No review completed yet. Reviewer must submit review first.')
    }
    if ($reviewResult -eq 'SHIP') {
        $result = [ordered]@{
            success = $true
            shipped = $true
            message = 'Work approved! SHIPPED.'
            status  = $status
        }
        return json-response -Id $Id -Result ([PSCustomObject]$result)
    }
    $result = [ordered]@{
        success   = $true
        shipped   = $false
        feedback  = $feedback
        iteration = $status['currentIteration']
        status    = $status
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-GetStatus {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $config = Get-Config -SessionId $sessionId
    $maxIterations = 10
    if ($config) {
        $configObj = JsonToDict $config
        $maxIterations = [int](Coalesce $configObj['maxIterations'] 10)
    }
    $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations
    $result = [ordered]@{ success = $true }
    foreach ($k in $status.Keys) { $result[$k] = $status[$k] }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-GetConfig {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $config = Get-Config -SessionId $sessionId
    if (-not $config) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'No configuration found. Initialize the session first with ralph_loop_initialize.')
    }
    $configObj = JsonToDict $config
    $validation = JsonToDict (Test-CrossModel -SessionId $sessionId)
    $enforced = if ($null -ne $configObj['crossModelReviewEnforced']) { [bool]$configObj['crossModelReviewEnforced'] } else { $true }
    $result = [ordered]@{
        success = $true
        config  = [ordered]@{
            workerModel              = Coalesce $configObj['workerModel'] ''
            workerProvider           = Coalesce $configObj['workerProvider'] ''
            workerAgent              = Coalesce $configObj['workerAgent'] ''
            reviewerModel            = Coalesce $configObj['reviewerModel'] ''
            reviewerProvider         = Coalesce $configObj['reviewerProvider'] ''
            reviewerAgent            = Coalesce $configObj['reviewerAgent'] ''
            monitorModel             = Coalesce $configObj['monitorModel'] ''
            monitorProvider          = Coalesce $configObj['monitorProvider'] ''
            monitorAgent             = Coalesce $configObj['monitorAgent'] ''
            maxIterations            = [int](Coalesce $configObj['maxIterations'] 10)
            crossModelReviewEnforced = $enforced
            workGuidelines           = Coalesce $configObj['workGuidelines'] ''
            reviewGuidelines         = Coalesce $configObj['reviewGuidelines'] ''
            configuredAt             = Coalesce $configObj['configuredAt'] ''
        }
        crossModelReview = [ordered]@{
            enforced = $enforced
            valid    = if ($null -ne $validation['valid']) { [bool]$validation['valid'] } else { $true }
            warning  = Coalesce $validation['warning'] ''
        }
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-Reset {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    Reset-Session -SessionId $sessionId
    $result = [ordered]@{
        success = $true
        message = "Session `"$sessionId`" has been reset"
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-Block {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $reason = Coalesce $paramsObj['reason'] ''
    if (-not $reason) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'Reason is required for blocking')
    }
    Block-Iteration -SessionId $sessionId -Reason $reason
    $result = [ordered]@{
        success = $true
        message = 'Iteration blocked'
        reason  = $reason
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Handle-Run {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce (Coalesce $paramsObj['sessionId'] $paramsObj['session_id']) 'default'
    $task = Coalesce $paramsObj['task'] ''
    $maxIterations = [int](Coalesce (Coalesce $paramsObj['maxIterations'] $paramsObj['max_iterations']) 10)
    $initialBackoff = [int](Coalesce (Coalesce $paramsObj['initialBackoff'] $paramsObj['initial_backoff']) 5)
    $throttleDelay = [int](Coalesce (Coalesce $paramsObj['throttleDelay'] $paramsObj['throttle_delay']) 0)
    $maxRetries = [int](Coalesce (Coalesce $paramsObj['maxRetries'] $paramsObj['max_retries']) 3)
    $workerModel = Coalesce (Coalesce $paramsObj['workerModel'] $paramsObj['worker_model']) ''
    $workerProvider = Coalesce (Coalesce $paramsObj['workerProvider'] $paramsObj['worker_provider']) ''
    $workerAgent = Coalesce (Coalesce $paramsObj['workerAgent'] $paramsObj['worker_agent']) 'goose'
    $reviewerModel = Coalesce (Coalesce $paramsObj['reviewerModel'] $paramsObj['reviewer_model']) ''
    $reviewerProvider = Coalesce (Coalesce $paramsObj['reviewerProvider'] $paramsObj['reviewer_provider']) ''
    $reviewerAgent = Coalesce (Coalesce $paramsObj['reviewerAgent'] $paramsObj['reviewer_agent']) 'goose'
    $crossModelRaw = Coalesce $paramsObj['crossModelReviewEnforced'] $paramsObj['cross_model_review_enforced']
    $crossModelEnforced = if ($null -ne $crossModelRaw -and $crossModelRaw -ne '') { [bool]$crossModelRaw } else { $true }
    $workGuidelines = Coalesce (Coalesce $paramsObj['workGuidelines'] $paramsObj['work_guidelines']) ''
    $reviewGuidelines = Coalesce (Coalesce $paramsObj['reviewGuidelines'] $paramsObj['review_guidelines']) ''
    $monitorModel = Coalesce (Coalesce $paramsObj['monitorModel'] $paramsObj['monitor_model']) $script:MonitorModel
    $monitorProvider = Coalesce (Coalesce $paramsObj['monitorProvider'] $paramsObj['monitor_provider']) $script:MonitorProvider
    $monitorAgent = Coalesce (Coalesce $paramsObj['monitorAgent'] $paramsObj['monitor_agent']) $script:MonitorAgent
    $adaptiveRaw = Coalesce $paramsObj['enableAdaptive'] $paramsObj['enable_adaptive']
    $enableAdaptive = if ($null -ne $adaptiveRaw -and $adaptiveRaw -ne '') { [bool]$adaptiveRaw } else { $false }
    $adaptiveStrategy = Coalesce (Coalesce $paramsObj['adaptiveStrategy'] $paramsObj['adaptive_strategy']) 'balanced'
    $currentProfile = Coalesce $paramsObj['profile'] ''

    if (-not $task) { return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'Task is required') }
    if (-not $workerModel -or -not $workerProvider -or -not $reviewerModel -or -not $reviewerProvider) {
        return json-response -Id $Id -Error (mcp-error -Code -32602 -Message 'workerModel, workerProvider, reviewerModel, and reviewerProvider are required')
    }

    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $crossModelEnforced -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -InitialBackoff $initialBackoff -ThrottleDelay $throttleDelay -MaxRetries $maxRetries

    if ($enableAdaptive) {
        if (-not $script:AdaptiveOrders.ContainsKey($adaptiveStrategy)) {
            $adaptiveStrategy = 'balanced'
        }
        if (-not $currentProfile) {
            $currentProfile = $script:AdaptiveOrders[$adaptiveStrategy]['start']
        }
    }

    $feedback = ''

    for ($i = 1; $i -le $maxIterations; $i++) {
        $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $i -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting ($i -gt 1)

        if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations; $initialBackoff = $sw.initialBackoff; $throttleDelay = $sw.throttleDelay; $maxRetries = $sw.maxRetries
                    $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $i -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting ($i -gt 1)
                }
            }
            if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
                Block-Iteration -SessionId $sessionId -Reason 'WORK PHASE FAILED - Rate limit or quota error from worker LLM'
                return json-response -Id $Id -Error (mcp-error -Code -32603 -Message 'WORK PHASE FAILED - Rate limit, quota error, or no output from worker')
            }
        }

        $workOutFile = Get-StateFile -SessionId $sessionId -FileName 'work.out'
        $workerOutput | Out-File -FilePath $workOutFile -Encoding UTF8

        $parsed = Parse-WorkerOutput -Output $workerOutput -OutputFile $workOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $work = $parsed.work; $summary = $parsed.summary
        if (-not $work -or -not $summary) {
            return json-response -Id $Id -Error (mcp-error -Code -32603 -Message 'WORK PHASE FAILED - Could not parse output')
        }

        Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $i

        $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $i -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting ($i -gt 1)

        if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations; $initialBackoff = $sw.initialBackoff; $throttleDelay = $sw.throttleDelay; $maxRetries = $sw.maxRetries
                    $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $i -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting ($i -gt 1)
                }
            }
            if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
                Block-Iteration -SessionId $sessionId -Reason 'REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM'
                return json-response -Id $Id -Error (mcp-error -Code -32603 -Message 'REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer')
            }
        }

        $reviewOutFile = Get-StateFile -SessionId $sessionId -FileName 'review.out'
        $reviewerOutput | Out-File -FilePath $reviewOutFile -Encoding UTF8

        $parsed = Parse-ReviewerOutput -Output $reviewerOutput -OutputFile $reviewOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $decision = $parsed.decision; $feedback = $parsed.feedback
        if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') {
            return json-response -Id $Id -Error (mcp-error -Code -32603 -Message ('REVIEW PHASE FAILED - Invalid decision: ' + $decision))
        }

        Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $i

        if ($decision -eq 'SHIP') {
            $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations
            $result = [ordered]@{
                success    = $true
                message    = "SHIPPED after $i iteration(s)"
                status     = $status
                shipped    = $true
                iterations = $i
            }
            return json-response -Id $Id -Result ([PSCustomObject]$result)
        }

        if ($enableAdaptive) {
            $trigger = ''
            if (Test-QualityTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'quality' }
            elseif (Test-ResourceTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'resource' }
            $newProfile = if ($trigger) { Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger $trigger -CurrentProfile $currentProfile } else { $null }
            if ($newProfile -and $newProfile -ne $currentProfile) {
                $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                $currentProfile = $newProfile
                $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                $maxIterations = $sw.maxIterations; $initialBackoff = $sw.initialBackoff; $throttleDelay = $sw.throttleDelay; $maxRetries = $sw.maxRetries
            }
        }
    }

    $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations
    $result = [ordered]@{
        success = $false
        message = "Max iterations ($maxIterations) reached"
        status  = $status
        shipped = $false
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function global:Handle-ListTools {
    param($Id)
    $tools = @(
        @{
            name        = 'ralph_loop_initialize'
            description = 'Initialize a new Ralph Loop session with a task, model configuration, and guidelines'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId                = @{ type = 'string'; description = "Unique session identifier (default: 'default')" }
                    task                     = @{ type = 'string'; description = 'The task or feature description for the worker to implement' }
                    maxIterations            = @{ type = 'integer'; description = 'Maximum number of iterations (-1 for unlimited, default: 10)' }
                    workerModel              = @{ type = 'string'; description = "Worker LLM model name (e.g., 'claude-3-5-sonnet')" }
                    workerProvider           = @{ type = 'string'; description = 'Worker provider (anthropic, openai, google, copilot, goose)' }
                    workerAgent              = @{ type = 'string'; description = "Worker agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    reviewerModel            = @{ type = 'string'; description = "Reviewer LLM model name (e.g., 'gpt-4o')" }
                    reviewerProvider         = @{ type = 'string'; description = 'Reviewer provider (anthropic, openai, google, copilot, goose)' }
                    reviewerAgent            = @{ type = 'string'; description = "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    monitorModel             = @{ type = 'string'; description = 'Monitoring agent model name (fallback supervisor)' }
                    monitorProvider          = @{ type = 'string'; description = 'Monitoring agent provider (anthropic, openai, google, copilot, goose)' }
                    monitorAgent             = @{ type = 'string'; description = "Monitoring agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    crossModelReviewEnforced = @{ type = 'boolean'; description = 'Enforce cross-model review validation between worker and reviewer (default: true)' }
                    workGuidelines           = @{ type = 'string'; description = 'Path to work recipe or guidelines file' }
                    reviewGuidelines         = @{ type = 'string'; description = 'Path to review recipe or guidelines file' }
                }
                required   = @('task')
            }
        },
        @{
            name        = 'ralph_loop_get_task'
            description = 'Get the current task for the worker phase'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name        = 'ralph_loop_submit_work'
            description = 'Submit work results and summary from worker phase'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    work      = @{ type = 'string'; description = 'Complete work output / implementation' }
                    summary   = @{ type = 'string'; description = 'Summary of changes made' }
                    iteration = @{ type = 'integer'; description = 'Current iteration number' }
                }
                required   = @('work', 'summary', 'iteration')
            }
        },
        @{
            name        = 'ralph_loop_get_work'
            description = "Get worker's submitted work for reviewer phase"
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name        = 'ralph_loop_submit_review'
            description = 'Submit review decision (SHIP or REVISE) with feedback'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    decision  = @{ type = 'string'; enum = @('SHIP', 'REVISE'); description = 'Review decision: SHIP to approve, REVISE to request changes' }
                    feedback  = @{ type = 'string'; description = 'Actionable feedback for revision (required if decision is REVISE)' }
                    iteration = @{ type = 'integer'; description = 'Current iteration number' }
                }
                required   = @('decision', 'iteration')
            }
        },
        @{
            name        = 'ralph_loop_get_feedback'
            description = 'Get reviewer feedback for next iteration'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name        = 'ralph_loop_get_status'
            description = 'Get current session status, phase, iteration, and configuration'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name        = 'ralph_loop_get_config'
            description = 'Get worker, reviewer, and monitor configuration for a session'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name        = 'ralph_loop_reset'
            description = 'Reset and clear all state and history for a session'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name        = 'ralph_loop_block'
            description = 'Block the current iteration with a reason'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    reason    = @{ type = 'string'; description = 'Reason why the loop cannot proceed' }
                }
                required   = @('reason')
            }
        },
        @{
            name        = 'ralph_loop_run'
            description = 'Run complete automated Ralph Loop (initialization -> orchestration -> execution -> state management)'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    sessionId                = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    task                     = @{ type = 'string'; description = 'Task description to accomplish' }
                    maxIterations            = @{ type = 'integer'; description = 'Maximum number of iterations (-1 for unlimited, default: 10)' }
                    workerModel              = @{ type = 'string'; description = 'Worker model name' }
                    workerProvider           = @{ type = 'string'; description = 'Worker provider (anthropic, openai, google, copilot, goose)' }
                    workerAgent              = @{ type = 'string'; description = "Worker agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    reviewerModel            = @{ type = 'string'; description = 'Reviewer model name' }
                    reviewerProvider         = @{ type = 'string'; description = 'Reviewer provider (anthropic, openai, google, copilot, goose)' }
                    reviewerAgent            = @{ type = 'string'; description = "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    monitorModel             = @{ type = 'string'; description = 'Monitor model name' }
                    monitorProvider          = @{ type = 'string'; description = 'Monitor provider' }
                    monitorAgent             = @{ type = 'string'; description = "Monitor agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    crossModelReviewEnforced = @{ type = 'boolean'; description = 'Enforce cross-model review validation (default: true)' }
                    workGuidelines           = @{ type = 'string'; description = 'Path to work recipe or guidelines file' }
                    reviewGuidelines         = @{ type = 'string'; description = 'Path to review recipe or guidelines file' }
                    enableAdaptive           = @{ type = 'boolean'; description = 'Enable adaptive profile switching (default: false)' }
                    adaptiveStrategy         = @{ type = 'string'; enum = @('quality', 'price', 'balanced'); description = 'Adaptive switching strategy (default: balanced)' }
                }
                required   = @('task', 'workerModel', 'workerProvider', 'reviewerModel', 'reviewerProvider')
            }
        }
    )
    $result = [ordered]@{ tools = $tools }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function Invoke-RalphToolDispatch {
    param($Id, [string]$ToolName, $ToolArgs)
    switch -Regex ($ToolName) {
        '^ral(ph|f)_loop_initialize$'    { return Handle-Initialize   -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_get_task$'      { return Handle-GetTask      -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_submit_work$'   { return Handle-SubmitWork   -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_get_work$'      { return Handle-GetWork      -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_submit_review$' { return Handle-SubmitReview -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_get_feedback$'  { return Handle-GetFeedback  -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_get_status$'    { return Handle-GetStatus    -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_get_config$'    { return Handle-GetConfig    -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_reset$'         { return Handle-Reset        -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_block$'         { return Handle-Block        -Id $Id -Params $ToolArgs }
        '^ral(ph|f)_loop_run$'           { return Handle-Run          -Id $Id -Params $ToolArgs }
        default {
            return json-response -Id $Id -Error (mcp-error -Code -32601 -Message "Unknown tool: $ToolName")
        }
    }
}

function global:Handle-ToolsCall {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    $toolName = if ($null -ne $Params -and $Params.Contains('name')) { [string]$Params['name'] } else { '' }
    $toolArgs = if ($null -ne $Params -and $Params.Contains('arguments') -and $null -ne $Params['arguments']) {
        JsonToDict $Params['arguments']
    }
    else {
        @{}
    }
    return Invoke-RalphToolDispatch -Id $Id -ToolName $toolName -ToolArgs $toolArgs
}

function global:Invoke-McpCustomMethod {
    param($Id, [string]$Method, [System.Collections.IDictionary]$Params = @{}, [bool]$IsNotification = $false)
    if ($Method -match '^ral(ph|f)_loop_') {
        return Invoke-RalphToolDispatch -Id $Id -ToolName $Method -ToolArgs $Params
    }
    if (-not $IsNotification -and $null -ne $Id -and $Id -ne 'null' -and [string]$Id -ne '') {
        return json-response -Id $Id -Error (mcp-error -Code -32601 -Message "Method not found: $Method")
    }
    return $null
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
$pipedLines = @($input)
if ($args.Count -eq 0) {
    if ($pipedLines.Count -gt 0) { $pipedLines | Start-McpServer } else { Start-McpServer }
    exit 0
}
elseif ($args[0] -eq '--stdio') {
    if ($pipedLines.Count -gt 0) { $pipedLines | Start-McpServer -Transport 'stdio' } else { Start-McpServer -Transport 'stdio' }
    exit 0
}
elseif ($args[0] -eq '--http' -or $args[0] -eq '--streamable-http') {
    $port = 8080
    $hostName = '127.0.0.1'
    for ($i = 1; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '--port' -and ($i + 1) -lt $args.Count) { $port = [int]$args[++$i] }
        elseif ($args[$i] -eq '--host' -and ($i + 1) -lt $args.Count) { $hostName = [string]$args[++$i] }
    }
    Start-McpServer -Transport 'streamable-http' -HostName $hostName -Port $port
    exit 0
}
else {
    $script:ScriptArgs = $args
    Run-Cli
    exit 0
}
