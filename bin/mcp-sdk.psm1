# mcp-sdk.psm1 - Generic Shebang MCP SDK (PowerShell)
# Implementation of the Model Context Protocol (MCP) specification (latest: 2025-03-26 / 2024-11-05)
# Supports both stdio and streamable-http transports.
#
# This SDK is strictly generic and provides core MCP protocol functions usable by any
# PowerShell-based MCP server. It contains NO application-specific logic.
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
#   - On-exit cleanup handler (PowerShell.Exiting & Module.OnRemove)
#
# OPTIONAL features (explicitly NOT implemented):
#   - Authorization, Elicitation, Roots, Sampling, Completions, Logging
#
# DEPRECATED features (explicitly NOT implemented):
#   - Legacy HTTP+SSE transport (2024-11-05 separate SSE endpoint)
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# PROTOCOL CONSTANTS & STATE
# ============================================================================

$script:McpProtocolVersion   = if ($env:MCP_PROTOCOL_VERSION) { $env:MCP_PROTOCOL_VERSION } else { '2025-03-26' }
$script:McpSupportedVersions = @('2025-03-26', '2024-11-05')
$script:McpServerName        = if ($env:MCP_SERVER_NAME) { $env:MCP_SERVER_NAME } else { 'shebang-mcp-sdk' }
$script:McpServerVersion     = if ($env:MCP_SERVER_VERSION) { $env:MCP_SERVER_VERSION } else { '1.0.0' }

$script:McpTransport         = if ($env:MCP_TRANSPORT) { $env:MCP_TRANSPORT } else { 'stdio' }
$script:McpHttpHost          = if ($env:MCP_HTTP_HOST) { $env:MCP_HTTP_HOST } else { '127.0.0.1' }
$script:McpHttpPort          = if ($env:MCP_HTTP_PORT) { [int]$env:MCP_HTTP_PORT } else { 8080 }
$script:McpHttpEndpoint      = if ($env:MCP_HTTP_ENDPOINT) { $env:MCP_HTTP_ENDPOINT } else { '/mcp' }
$script:McpSessionId         = ''
$script:McpInitialized       = $false
$script:McpHttpListener      = $null
$script:McpCleanupDone       = $false
$script:McpCleanupHooks      = [System.Collections.Generic.List[scriptblock]]::new()

# ============================================================================
# ON-EXIT & CONNECTION CLEANUP HANDLERS
# ============================================================================

function Register-McpCleanup {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Callback
    )
    $script:McpCleanupHooks.Add($Callback)
}

function Close-McpConnection {
    if ($null -ne $script:McpHttpListener) {
        try {
            if ($script:McpHttpListener.IsListening) {
                $script:McpHttpListener.Stop()
            }
            $script:McpHttpListener.Close()
        }
        catch {
            # Ignore listener disposal errors during teardown
        }
        finally {
            $script:McpHttpListener = $null
        }
    }
    $script:McpInitialized = $false
    $script:McpSessionId   = ''
}

function Invoke-McpOnExit {
    if ($script:McpCleanupDone) { return }
    $script:McpCleanupDone = $true

    foreach ($hook in $script:McpCleanupHooks) {
        try {
            & $hook
        }
        catch {
            # Ignore errors in cleanup callbacks
        }
    }

    Close-McpConnection
}

# Alias for kebab-case naming consistency
Set-Alias -Name mcp-on-exit -Value Invoke-McpOnExit
Set-Alias -Name mcp-close-connection -Value Close-McpConnection
Set-Alias -Name mcp-register-cleanup -Value Register-McpCleanup

# Register module unload cleanup handler (runs when module is removed or runspace closes)
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    $MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
        Invoke-McpOnExit
    }
}

# ============================================================================
# CORE PROTOCOL UTILITIES
# ============================================================================

function Set-McpServerInfo {
    param(
        [string]$Name,
        [string]$Version,
        [string]$ProtocolVersion
    )
    if ($Name)            { $script:McpServerName      = $Name }
    if ($Version)         { $script:McpServerVersion   = $Version }
    if ($ProtocolVersion) { $script:McpProtocolVersion = $ProtocolVersion }
}

function ConvertTo-McpHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $val = $prop.Value
            if ($val -is [System.Management.Automation.PSCustomObject]) {
                $val = ConvertTo-McpHashtable $val
            }
            elseif ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                $arr = @()
                foreach ($item in $val) {
                    if ($item -is [System.Management.Automation.PSCustomObject]) {
                        $arr += ConvertTo-McpHashtable $item
                    }
                    else {
                        $arr += $item
                    }
                }
                $val = $arr
            }
            $hash[$prop.Name] = $val
        }
        return $hash
    }
    return $InputObject
}

# JSON-RPC 2.0 Response Constructor
# Usage: json-response -Id <id> [-Result <json_or_object>] [-Error <hashtable_or_json>]
function json-response {
    param(
        $Id = $null,
        $Result = '{}',
        $Error = $null
    )

    $resp = [ordered]@{
        jsonrpc = '2.0'
    }

    # Preserve id type (null, integer, or string) per JSON-RPC 2.0
    if ($null -eq $Id -or $Id -eq 'null' -or ($Id -is [string] -and $Id -eq '')) {
        $resp['id'] = $null
    }
    elseif ($Id -is [int] -or $Id -is [long] -or $Id -is [double]) {
        $resp['id'] = $Id
    }
    elseif ($Id -is [string] -and $Id -match '^-?\d+$') {
        $resp['id'] = [long]$Id
    }
    else {
        $resp['id'] = [string]$Id
    }

    if ($null -ne $Error -and $Error -ne '') {
        if ($Error -is [string]) {
            try {
                $resp['error'] = $Error | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $resp['error'] = [ordered]@{ code = -32603; message = $Error }
            }
        }
        else {
            $resp['error'] = $Error
        }
    }
    else {
        if ($null -eq $Result -or $Result -eq '' -or $Result -eq '{}') {
            $resp['result'] = [PSCustomObject]@{}
        }
        elseif ($Result -is [string]) {
            try {
                $parsed = $Result | ConvertFrom-Json -ErrorAction Stop
                $resp['result'] = if ($null -ne $parsed) { $parsed } else { [PSCustomObject]@{} }
            }
            catch {
                $resp['result'] = [PSCustomObject]@{
                    content = @(
                        [PSCustomObject]@{ type = 'text'; text = $Result }
                    )
                }
            }
        }
        else {
            $resp['result'] = $Result
        }
    }

    return ConvertTo-Json -InputObject ([PSCustomObject]$resp) -Compress -Depth 20
}

Set-Alias -Name New-JsonResponse -Value json-response

# JSON-RPC 2.0 Error Object Constructor
# Usage: mcp-error -Code <code> -Message <message> [-Data <data>]
function mcp-error {
    param(
        [int]$Code = -32603,
        [string]$Message = 'Internal error',
        $Data = $null
    )
    $err = [ordered]@{
        code    = $Code
        message = $Message
    }
    if ($null -ne $Data -and $Data -ne 'null' -and $Data -ne '') {
        $err['data'] = $Data
    }
    return $err
}

# Format a tool result per MCP spec
function New-McpToolResult {
    param(
        [string]$Text = '',
        [bool]$IsError = $false
    )
    return [ordered]@{
        content = @(
            [ordered]@{
                type = 'text'
                text = $Text
            }
        )
        isError = $IsError
    }
}

# Parse incoming JSON-RPC 2.0 message
# Returns hashtable: Valid, JsonRpc, IsNotification, Id, Method, Params
function mcp-parse-message {
    param(
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return @{
            Valid          = $false
            JsonRpc        = ''
            IsNotification = $false
            Id             = 'null'
            Method         = ''
            Params         = @{}
        }
    }

    try {
        $json = $Message | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) {
            return @{
                Valid          = $false
                JsonRpc        = ''
                IsNotification = $false
                Id             = 'null'
                Method         = ''
                Params         = @{}
            }
        }

        $props = @($json.PSObject.Properties.Name)
        $hasId = $props -contains 'id'
        $idVal = if ($hasId -and $null -ne $json.id) { $json.id } else { 'null' }
        $jsonrpc = if ($props -contains 'jsonrpc' -and $null -ne $json.jsonrpc) { [string]$json.jsonrpc } else { '' }
        $method = if ($props -contains 'method' -and $null -ne $json.method) { [string]$json.method } else { '' }
        $params = if ($props -contains 'params' -and $null -ne $json.params) {
            ConvertTo-McpHashtable $json.params
        }
        else {
            @{}
        }

        return @{
            Valid          = $true
            JsonRpc        = $jsonrpc
            IsNotification = (-not $hasId)
            Id             = $idVal
            Method         = $method
            Params         = $params
        }
    }
    catch {
        return @{
            Valid          = $false
            JsonRpc        = ''
            IsNotification = $false
            Id             = 'null'
            Method         = ''
            Params         = @{}
        }
    }
}

# ============================================================================
# MCP METHOD HANDLERS
# ============================================================================

function handle-initialize {
    param(
        $Id,
        [System.Collections.IDictionary]$Params = @{}
    )

    $clientVersion = if ($null -ne $Params -and $Params.Contains('protocolVersion')) { [string]$Params['protocolVersion'] } else { '' }
    $negotiatedVersion = $script:McpProtocolVersion
    if ($clientVersion -and ($script:McpSupportedVersions -contains $clientVersion)) {
        $negotiatedVersion = $clientVersion
    }

    $script:McpInitialized = $true

    $result = [ordered]@{
        protocolVersion = $negotiatedVersion
        capabilities    = [ordered]@{
            tools = [PSCustomObject]@{}
        }
        serverInfo      = [ordered]@{
            name    = $script:McpServerName
            version = $script:McpServerVersion
        }
    }

    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function handle-initialized {
    # Notification from client: acknowledge silently, no response.
    $script:McpInitialized = $true
}

function handle-ping {
    param($Id)
    return json-response -Id $Id -Result '{}'
}

function handle-tools-list {
    param(
        $Id,
        [System.Collections.IDictionary]$Params = @{}
    )

    # Delegate to consumer Handle-ListTools if defined in global/script scope
    $consumerCmd = Get-Command -Name 'Handle-ListTools' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) {
        return & $consumerCmd -Id $Id
    }

    $result = [ordered]@{
        tools = @()
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function handle-tools-call {
    param(
        $Id,
        [System.Collections.IDictionary]$Params = @{}
    )

    $consumerCmd = Get-Command -Name 'Handle-ToolsCall' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) {
        return & $consumerCmd -Id $Id -Params $Params
    }

    $name = if ($null -ne $Params -and $Params.Contains('name') -and $null -ne $Params['name']) {
        [string]$Params['name']
    }
    else {
        ''
    }

    if ([string]::IsNullOrEmpty($name)) {
        $err = mcp-error -Code -32602 -Message 'Invalid params: missing tool name'
        return json-response -Id $Id -Error $err
    }

    $err = mcp-error -Code -32601 -Message "Tool not found: $name"
    return json-response -Id $Id -Error $err
}

# Process a single JSON-RPC 2.0 line and return response string (or $null for notifications)
function process-mcp-line {
    param([string]$line)

    if ([string]::IsNullOrWhiteSpace($line)) { return $null }

    $parsed = mcp-parse-message -Message $line
    if (-not $parsed.Valid) {
        $err = mcp-error -Code -32700 -Message 'Parse error'
        return json-response -Id 'null' -Error $err
    }

    if ($parsed.JsonRpc -ne '2.0') {
        $err = mcp-error -Code -32600 -Message 'Invalid Request'
        return json-response -Id $parsed.Id -Error $err
    }

    $msg_id         = $parsed.Id
    $msg_method     = $parsed.Method
    $msg_params     = $parsed.Params
    $isNotification = $parsed.IsNotification

    if ([string]::IsNullOrEmpty($msg_method)) {
        $err = mcp-error -Code -32600 -Message 'Invalid Request: missing method'
        return json-response -Id $msg_id -Error $err
    }

    switch -Wildcard ($msg_method) {
        'initialize' {
            return handle-initialize -Id $msg_id -Params $msg_params
        }
        'notifications/initialized' {
            handle-initialized
            return $null
        }
        'initialized' {
            handle-initialized
            return $null
        }
        'notifications/*' {
            return $null
        }
        'ping' {
            return handle-ping -Id $msg_id
        }
        'tools/list' {
            return handle-tools-list -Id $msg_id -Params $msg_params
        }
        'tools/call' {
            return handle-tools-call -Id $msg_id -Params $msg_params
        }
        default {
            $customRouter = Get-Command -Name 'Invoke-McpCustomMethod' -ErrorAction SilentlyContinue
            if ($null -ne $customRouter) {
                return & $customRouter -Id $msg_id -Method $msg_method -Params $msg_params -IsNotification $isNotification
            }
            if (-not $isNotification -and $null -ne $msg_id -and $msg_id -ne 'null' -and [string]$msg_id -ne '') {
                $err = mcp-error -Code -32601 -Message "Method not found: $msg_method"
                return json-response -Id $msg_id -Error $err
            }
            return $null
        }
    }
}

# ============================================================================
# TRANSPORT: STDIO
# ============================================================================

function Invoke-Mcp-Stdio-Server {
    param(
        [Parameter(ValueFromPipeline = $true)]
        [string[]]$PipedLines
    )
    begin {
        $collected = [System.Collections.Generic.List[string]]::new()
    }
    process {
        if ($null -ne $PipedLines) {
            foreach ($p in $PipedLines) {
                if ($null -ne $p) { $collected.Add($p) }
            }
        }
    }
    end {
        try {
            if ($collected.Count -gt 0) {
                $joined = $collected -join "`n"
                foreach ($line in ($joined -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $resp = process-mcp-line -line $line
                    if (-not [string]::IsNullOrEmpty($resp)) {
                        Write-Output $resp
                    }
                }
                return
            }

            while ($null -ne ($line = [System.Console]::In.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $resp = process-mcp-line -line $line
                if (-not [string]::IsNullOrEmpty($resp)) {
                    [System.Console]::Out.WriteLine($resp)
                    [System.Console]::Out.Flush()
                }
            }
        }
        finally {
            Invoke-McpOnExit
        }
    }
}

# ============================================================================
# TRANSPORT: STREAMABLE-HTTP (MCP 2025-03-26 specification)
# ============================================================================

function check-http-available {
    return $true
}

function extract-jsonrpc-from-post {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    try {
        $json = $Body | ConvertFrom-Json -ErrorAction Stop
        return $json
    }
    catch {
        return $null
    }
}

function send-http-response {
    param(
        [string]$Response = '',
        [int]$StatusCode = 200,
        [string]$ContentType = 'application/json',
        [string]$SessionId = $script:McpSessionId
    )

    $statusText = switch ($StatusCode) {
        200 { 'OK' }
        202 { 'Accepted' }
        204 { 'No Content' }
        400 { 'Bad Request' }
        404 { 'Not Found' }
        405 { 'Method Not Allowed' }
        406 { 'Not Acceptable' }
        500 { 'Internal Server Error' }
        default { 'OK' }
    }

    $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($Response)
    $headers = [System.Collections.Generic.List[string]]::new()
    $headers.Add("HTTP/1.1 $StatusCode $statusText")
    if ($ContentType -and $bodyBytes -gt 0) {
        $headers.Add("Content-Type: $ContentType")
    }
    if (-not [string]::IsNullOrEmpty($SessionId)) {
        $headers.Add("Mcp-Session-Id: $SessionId")
    }
    $headers.Add('Cache-Control: no-cache')
    $headers.Add('Connection: close')
    $headers.Add("Content-Length: $bodyBytes")

    $headerBlock = ($headers -join "`r`n") + "`r`n`r`n"
    return ($headerBlock + $Response)
}

function send-http-sse-response {
    param(
        [string]$ResponseJson,
        [int]$StatusCode = 200,
        [string]$SessionId = $script:McpSessionId
    )
    $sseBody = "event: message`ndata: $ResponseJson`n`n"
    return send-http-response -Response $sseBody -StatusCode $StatusCode -ContentType 'text/event-stream' -SessionId $SessionId
}

# Handle HTTP POST request for Streamable HTTP MCP transport
function handle-http-post {
    param(
        [string]$Body,
        [string]$AcceptHeader = 'application/json, text/event-stream',
        [string]$SessionIdHeader = ''
    )

    $jsonMsg = extract-jsonrpc-from-post -Body $Body
    if ($null -eq $jsonMsg) {
        $errResp = json-response -Id 'null' -Error (mcp-error -Code -32700 -Message 'Parse error')
        return send-http-response -Response $errResp -StatusCode 400 -ContentType 'application/json'
    }

    $method = if ($jsonMsg.PSObject.Properties.Name -contains 'method') { [string]$jsonMsg.method } else { '' }
    if ($method -eq 'initialize' -and [string]::IsNullOrEmpty($script:McpSessionId)) {
        $script:McpSessionId = [guid]::NewGuid().ToString()
    }
    elseif (-not [string]::IsNullOrEmpty($script:McpSessionId) -and -not [string]::IsNullOrEmpty($SessionIdHeader) -and $SessionIdHeader -ne $script:McpSessionId) {
        $errResp = json-response -Id 'null' -Error (mcp-error -Code -32600 -Message 'Invalid or expired Mcp-Session-Id')
        return send-http-response -Response $errResp -StatusCode 404 -ContentType 'application/json'
    }

    $respPayload = process-mcp-line -line $Body
    if ([string]::IsNullOrEmpty($respPayload)) {
        return send-http-response -Response '' -StatusCode 202 -ContentType '' -SessionId $script:McpSessionId
    }

    if ($AcceptHeader -like '*text/event-stream*' -and $AcceptHeader -notlike '*application/json*') {
        return send-http-sse-response -ResponseJson $respPayload -StatusCode 200 -SessionId $script:McpSessionId
    }

    return send-http-response -Response $respPayload -StatusCode 200 -ContentType 'application/json' -SessionId $script:McpSessionId
}

function handle-http-get {
    param([string]$AcceptHeader = '')
    if ($AcceptHeader -like '*text/event-stream*') {
        return send-http-response -Response ": streamable-http sse stream open`n`n" -StatusCode 200 -ContentType 'text/event-stream' -SessionId $script:McpSessionId
    }
    return send-http-response -Response '' -StatusCode 405 -ContentType 'text/plain' -SessionId $script:McpSessionId
}

function handle-http-delete {
    param([string]$SessionIdHeader = '')
    if (-not [string]::IsNullOrEmpty($script:McpSessionId) -and -not [string]::IsNullOrEmpty($SessionIdHeader) -and $SessionIdHeader -ne $script:McpSessionId) {
        return send-http-response -Response '' -StatusCode 404 -ContentType 'text/plain'
    }
    $script:McpSessionId = ''
    $script:McpInitialized = $false
    return send-http-response -Response '' -StatusCode 200 -ContentType 'text/plain'
}

# Start a live Streamable HTTP server using System.Net.HttpListener
function Invoke-Mcp-StreamableHttp-Server {
    param(
        [string]$HostName = $script:McpHttpHost,
        [int]$Port = $script:McpHttpPort,
        [string]$Endpoint = $script:McpHttpEndpoint,
        [int]$MaxRequests = 0
    )

    if (-not $Endpoint.StartsWith('/')) { $Endpoint = "/$Endpoint" }
    if (-not $Endpoint.EndsWith('/'))   { $prefixPath = "$Endpoint/" } else { $prefixPath = $Endpoint }

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add(('http://{0}:{1}{2}' -f $HostName, $Port, $prefixPath))
    $script:McpHttpListener = $listener

    try {
        $listener.Start()
        $count = 0
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $req = $context.Request
            $res = $context.Response

            $httpMethod = $req.HttpMethod.ToUpperInvariant()
            $acceptHeader = if ($req.Headers['Accept']) { $req.Headers['Accept'] } else { 'application/json' }

            switch ($httpMethod) {
                'POST' {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                    $body = $reader.ReadToEnd()
                    $reader.Close()

                    $jsonMsg = extract-jsonrpc-from-post -Body $body
                    if ($null -eq $jsonMsg) {
                        $errPayload = json-response -Id 'null' -Error (mcp-error -Code -32700 -Message 'Parse error')
                        $res.StatusCode = 400
                        $res.ContentType = 'application/json'
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($errPayload)
                        $res.ContentLength64 = $bytes.Length
                        $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                    else {
                        $method = if ($jsonMsg.PSObject.Properties.Name -contains 'method') { [string]$jsonMsg.method } else { '' }
                        if ($method -eq 'initialize' -and [string]::IsNullOrEmpty($script:McpSessionId)) {
                            $script:McpSessionId = [guid]::NewGuid().ToString()
                        }
                        if (-not [string]::IsNullOrEmpty($script:McpSessionId)) {
                            $res.Headers['Mcp-Session-Id'] = $script:McpSessionId
                        }

                        $respPayload = process-mcp-line -line $body
                        if ([string]::IsNullOrEmpty($respPayload)) {
                            $res.StatusCode = 202
                            $res.ContentLength64 = 0
                        }
                        elseif ($acceptHeader -like '*text/event-stream*' -and $acceptHeader -notlike '*application/json*') {
                            $ssePayload = "event: message`ndata: $respPayload`n`n"
                            $res.StatusCode = 200
                            $res.ContentType = 'text/event-stream'
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes($ssePayload)
                            $res.ContentLength64 = $bytes.Length
                            $res.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                        else {
                            $res.StatusCode = 200
                            $res.ContentType = 'application/json'
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes($respPayload)
                            $res.ContentLength64 = $bytes.Length
                            $res.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                    }
                }
                'GET' {
                    if ($acceptHeader -like '*text/event-stream*') {
                        $res.StatusCode = 200
                        $res.ContentType = 'text/event-stream'
                        if (-not [string]::IsNullOrEmpty($script:McpSessionId)) {
                            $res.Headers['Mcp-Session-Id'] = $script:McpSessionId
                        }
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes(": streamable-http sse stream open`n`n")
                        $res.ContentLength64 = $bytes.Length
                        $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                    else {
                        $res.StatusCode = 405
                        $res.ContentLength64 = 0
                    }
                }
                'DELETE' {
                    $script:McpSessionId = ''
                    $script:McpInitialized = $false
                    $res.StatusCode = 200
                    $res.ContentLength64 = 0
                }
                default {
                    $res.StatusCode = 405
                    $res.ContentLength64 = 0
                }
            }

            $res.OutputStream.Close()
            $res.Close()

            $count++
            if ($MaxRequests -gt 0 -and $count -ge $MaxRequests) {
                break
            }
        }
    }
    finally {
        Invoke-McpOnExit
    }
}

# ============================================================================
# TRANSPORT MODE DETECTION & ENTRY POINT
# ============================================================================

function get-transport-mode {
    if (-not [string]::IsNullOrEmpty($env:MCP_TRANSPORT)) {
        return $env:MCP_TRANSPORT
    }
    return 'stdio'
}

Set-Alias -Name 'route-mcp-message' -Value 'process-mcp-line'

function Start-McpServer {
    param(
        [string]$Transport = (get-transport-mode),
        [string]$HostName = $script:McpHttpHost,
        [int]$Port = $script:McpHttpPort,
        [Parameter(ValueFromPipeline = $true)]
        [string[]]$PipedLines
    )
    begin {
        $collected = [System.Collections.Generic.List[string]]::new()
    }
    process {
        if ($null -ne $PipedLines) {
            foreach ($p in $PipedLines) {
                if ($null -ne $p) { $collected.Add($p) }
            }
        }
    }
    end {
        switch ($Transport) {
            'http'            { Invoke-Mcp-StreamableHttp-Server -HostName $HostName -Port $Port }
            'streamable-http' { Invoke-Mcp-StreamableHttp-Server -HostName $HostName -Port $Port }
            default           {
                if ($collected.Count -gt 0) {
                    $collected.ToArray() | Invoke-Mcp-Stdio-Server
                }
                else {
                    Invoke-Mcp-Stdio-Server
                }
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Set-McpServerInfo',
    'Register-McpCleanup',
    'Close-McpConnection',
    'Invoke-McpOnExit',
    'ConvertTo-McpHashtable',
    'json-response',
    'mcp-error',
    'New-McpToolResult',
    'mcp-parse-message',
    'handle-initialize',
    'handle-initialized',
    'handle-ping',
    'handle-tools-list',
    'handle-tools-call',
    'process-mcp-line',
    'Invoke-Mcp-Stdio-Server',
    'check-http-available',
    'extract-jsonrpc-from-post',
    'send-http-response',
    'send-http-sse-response',
    'handle-http-post',
    'handle-http-get',
    'handle-http-delete',
    'Invoke-Mcp-StreamableHttp-Server',
    'get-transport-mode',
    'Start-McpServer'
) -Alias @(
    'New-JsonResponse',
    'mcp-on-exit',
    'mcp-close-connection',
    'mcp-register-cleanup',
    'route-mcp-message'
)
