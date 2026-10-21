#Requires -Version 5.1
# Ralph Wiggum Loop - Streamable HTTP Service Manager (Windows - PowerShell)
# Starts, stops, or checks the status of the Streamable HTTP MCP server.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
function Resolve-PluginRoot {
    if ($env:PLUGIN_ROOT -and (Test-Path (Join-Path $env:PLUGIN_ROOT 'bin\ralph-wiggum-loop.ps1'))) {
        return $env:PLUGIN_ROOT
    }
    foreach ($rel in @('..\..\..', '..\..\..\..')) {
        $cand = Join-Path $ScriptDir $rel
        if (Test-Path $cand) {
            $resolved = (Resolve-Path $cand).Path
            if (Test-Path (Join-Path $resolved 'bin\ralph-wiggum-loop.ps1')) {
                return $resolved
            }
        }
    }
    return (Get-Location).Path
}
$PluginRoot = Resolve-PluginRoot
$ServerScript = Join-Path $PluginRoot 'bin\ralph-wiggum-loop.ps1'

$Action = 'start'
$HostName = if ($env:MCP_HTTP_HOST) { $env:MCP_HTTP_HOST } else { '127.0.0.1' }
$Port = if ($env:MCP_HTTP_PORT) { [int]$env:MCP_HTTP_PORT } else { 8080 }
$Endpoint = if ($env:MCP_HTTP_ENDPOINT) { $env:MCP_HTTP_ENDPOINT } else { '/mcp' }
$StateDir = if ($env:PLUGIN_DATA) { $env:PLUGIN_DATA } else { Join-Path $PluginRoot '.ralph' }
$PidFile = Join-Path $StateDir 'ralph-http-server.pid'
$LogFile = Join-Path $StateDir 'ralph-http-server.log'
$ErrFile = Join-Path $StateDir 'ralph-http-server.err.log'

$idx = 0
while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    switch ($arg) {
        { $_ -in @('start', 'stop', 'status', 'foreground') } {
            $Action = $arg
            $idx++
        }
        '--host' {
            $HostName = [string]$args[$idx + 1]
            $idx += 2
        }
        '--port' {
            $Port = [int]$args[$idx + 1]
            $idx += 2
        }
        '--endpoint' {
            $Endpoint = [string]$args[$idx + 1]
            $idx += 2
        }
        { $_ -in @('-h', '--help') } {
            Write-Output @"
Ralph Wiggum Loop - Streamable HTTP Service Manager (Windows PowerShell)

USAGE:
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\skills\ralph-wiggum-loop\scripts\start-http-server.ps1 [start|stop|status|foreground] [OPTIONS]

COMMANDS:
  start        Start the Streamable HTTP MCP server in the background (default)
  foreground   Run the Streamable HTTP MCP server in the foreground
  status       Check if the server is running and responsive via HTTP POST ping
  stop         Stop the background server cleanly

OPTIONS:
  --host <ip>        Bind address (default: 127.0.0.1)
  --port <port>      TCP port (default: 8080)
  --endpoint <path>  MCP HTTP endpoint path (default: /mcp)
  -h, --help         Show this help message
"@
            exit 0
        }
        default {
            [Console]::Error.WriteLine("Unknown argument: $arg")
            exit 1
        }
    }
}

if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

function Get-RunningServerPid {
    if (Test-Path -LiteralPath $PidFile) {
        $rawPid = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($rawPid -and ($rawPid -match '^\d+$')) {
            $proc = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
            if ($null -ne $proc -and -not $proc.HasExited) {
                return [int]$rawPid
            }
        }
    }
    return $null
}

$PsExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    (Get-Command pwsh).Source
}
else {
    (Get-Command powershell.exe).Source
}

switch ($Action) {
    'foreground' {
        $env:MCP_TRANSPORT = 'streamable-http'
        $env:MCP_HTTP_HOST = $HostName
        $env:MCP_HTTP_PORT = [string]$Port
        $env:MCP_HTTP_ENDPOINT = $Endpoint
        Write-Output "Starting Ralph Wiggum Loop Streamable HTTP server (foreground) at http://${HostName}:${Port}${Endpoint} ..."
        & $ServerScript '--streamable-http' '--host' $HostName '--port' ([string]$Port)
    }

    'start' {
        $runningPid = Get-RunningServerPid
        if ($null -ne $runningPid) {
            Write-Output "Streamable HTTP server is already running (PID: $runningPid) at http://${HostName}:${Port}${Endpoint}"
            exit 0
        }

        $env:MCP_TRANSPORT = 'streamable-http'
        $env:MCP_HTTP_HOST = $HostName
        $env:MCP_HTTP_PORT = [string]$Port
        $env:MCP_HTTP_ENDPOINT = $Endpoint

        $procArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$ServerScript`"",
            '--streamable-http',
            '--host', $HostName,
            '--port', ([string]$Port)
        )

        $proc = Start-Process -FilePath $PsExe -ArgumentList $procArgs -WorkingDirectory $PluginRoot `
            -RedirectStandardOutput $LogFile -RedirectStandardError $ErrFile -WindowStyle Hidden -PassThru

        Set-Content -LiteralPath $PidFile -Value ([string]$proc.Id) -NoNewline
        Start-Sleep -Milliseconds 500

        Write-Output "Started Ralph Wiggum Loop Streamable HTTP server (PID: $($proc.Id))"
        Write-Output "  Endpoint: http://${HostName}:${Port}${Endpoint}"
        Write-Output "  Log file: $LogFile"
        Write-Output "  PID file: $PidFile"
    }

    'status' {
        $runningPid = Get-RunningServerPid
        if ($null -ne $runningPid) {
            $url = "http://${HostName}:${Port}${Endpoint}"
            try {
                $pingBody = '{"jsonrpc":"2.0","id":1,"method":"ping"}'
                $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $pingBody -TimeoutSec 3
                Write-Output "RUNNING (PID: $runningPid) - $url (ping OK)"
            }
            catch {
                Write-Output "RUNNING (PID: $runningPid) - $url"
            }
            exit 0
        }
        else {
            Write-Output 'STOPPED'
            exit 1
        }
    }

    'stop' {
        $runningPid = Get-RunningServerPid
        if ($null -ne $runningPid) {
            try {
                $url = "http://${HostName}:${Port}${Endpoint}"
                Invoke-WebRequest -Uri $url -Method Delete -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue | Out-Null
            }
            catch {}
            Stop-Process -Id $runningPid -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $runningPid -Timeout 3 -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
            Write-Output "Stopped Streamable HTTP server (PID: $runningPid)"
        }
        else {
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
            Write-Output 'Streamable HTTP server is not running.'
        }
    }
}
