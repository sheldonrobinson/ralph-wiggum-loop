#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds multi-package MCPB bundles (ralph-wiggum-loop.sh.mcpb and ralph-wiggum-loop.pwsh.mcpb),
    renders platform-specific mcp.json from packaging/mcpb/mcp.template.json,
    and updates server.json with SHA-256 integrity hashes for the Official MCP Registry.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version = "",

    [Parameter(Mandatory = $false)]
    [string]$RepoOwner = "sheldonrobinson",

    [Parameter(Mandatory = $false)]
    [string]$RepoName = "ralph-wiggum-loop",

    [Parameter(Mandatory = $false)]
    [string]$OutDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path

if ([string]::IsNullOrWhiteSpace($Version)) {
    $pluginJsonPath = Join-Path $RepoRoot "plugin.json"
    if (Test-Path -LiteralPath $pluginJsonPath) {
        $pluginMeta = Get-Content -LiteralPath $pluginJsonPath -Raw | ConvertFrom-Json
        $Version = [string]$pluginMeta.version
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = "1.1.0"
    }
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $RepoRoot "dist"
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-McpbArchive {
    param(
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$DestinationMcpb
    )

    if (Test-Path -LiteralPath $DestinationMcpb) {
        Remove-Item -LiteralPath $DestinationMcpb -Force
    }

    $stageFull = (Resolve-Path -LiteralPath $StageDir).Path.TrimEnd('\', '/')
    $zipStream = [System.IO.File]::Open($DestinationMcpb, [System.IO.FileMode]::Create)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $files = Get-ChildItem -LiteralPath $stageFull -Recurse -File
            foreach ($file in $files) {
                $relPath = $file.FullName.Substring($stageFull.Length + 1).Replace('\', '/')
                $entry = $archive.CreateEntry($relPath, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $inStream = [System.IO.File]::OpenRead($file.FullName)
                    try {
                        $inStream.CopyTo($entryStream)
                    } finally {
                        $inStream.Dispose()
                    }
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $zipStream.Dispose()
    }
}

function Copy-RelFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $src = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Required bundle file not found: $src"
    }
    $dst = Join-Path $StageRoot $RelativePath
    $dstParent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstParent)) {
        New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
}

function Write-PlatformMcpJson {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][ValidateSet("sh", "pwsh")][string]$TargetPlatform
    )

    $rawTemplate = Get-Content -LiteralPath $TemplatePath -Raw
    if ($TargetPlatform -eq "sh") {
        $cmd = "sh"
        $argsJson = '["-c", "command -v jq >/dev/null 2>&1 || { for d in /opt/homebrew/bin /usr/local/bin; do [ -d \"$d\" ] && [ \"${PATH#*$d}\" = \"$PATH\" ] && PATH=\"$d:$PATH\"; done; export PATH; }; exec sh \"$0\" \"$@\"", "${PLUGIN_ROOT}/bin/ralph-wiggum-loop.sh", "--stdio"]'
    } else {
        $cmd = "pwsh"
        $argsJson = '["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/ralph-wiggum-loop.ps1", "-Stdio"]'
    }

    $rendered = $rawTemplate.Replace("{{MCP_STDIO_COMMAND}}", $cmd).Replace("{{MCP_STDIO_ARGS_JSON}}", $argsJson)
    # Validate rendered JSON and format cleanly
    $parsed = $rendered | ConvertFrom-Json

    if ($TargetPlatform -eq "pwsh") {
        # Include powershell.exe (Windows PowerShell 5.1) as a secondary fallback entry
        $parsed.mcpServers | Add-Member -NotePropertyName "ralph-wiggum-loop-powershell" -NotePropertyValue ([ordered]@{
            type    = "stdio"
            command = "powershell.exe"
            args    = @(
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                "`${PLUGIN_ROOT}/bin/ralph-wiggum-loop.ps1",
                "-Stdio"
            )
            cwd     = "`${PLUGIN_ROOT}"
            env     = [ordered]@{
                RALPH_STATE_BASE = "`${PLUGIN_DATA}/state"
                RALPH_RECIPE_DIR = "`${PLUGIN_ROOT}/recipes"
            }
        }) -Force
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($DestinationPath, (($parsed | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)
}

$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("ralph-mcpb-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
$mcpTemplatePath = Join-Path $RepoRoot "packaging/mcpb/mcp.template.json"

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # -------------------------------------------------------------------------
    # 1. Stage & Build ralph-wiggum-loop.sh.mcpb (Bash edition: linux, darwin)
    # -------------------------------------------------------------------------
    $stageSh = Join-Path $tempBase "sh"
    New-Item -ItemType Directory -Path $stageSh -Force | Out-Null

    $manifestShSrc = Join-Path $RepoRoot "packaging/mcpb/manifest.sh.json"
    $manifestShObj = Get-Content -LiteralPath $manifestShSrc -Raw | ConvertFrom-Json
    $manifestShObj.version = $Version
    [System.IO.File]::WriteAllText((Join-Path $stageSh "manifest.json"), (($manifestShObj | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)

    Write-PlatformMcpJson -TemplatePath $mcpTemplatePath -DestinationPath (Join-Path $stageSh "mcp.json") -TargetPlatform "sh"

    $shFiles = @(
        "bin/ralph-wiggum-loop.sh",
        "bin/mcp-sdk.sh",
        "bin/script-runner",
        "bin/script-runner.sh",
        "profiles/lite.json",
        "profiles/plus.json",
        "profiles/pro.json",
        "profiles/super.json",
        "profiles/ultra.json",
        "skills/ralph-wiggum-loop/SKILL.md",
        "skills/ralph-wiggum-loop/references/checklist.md",
        "skills/ralph-wiggum-loop/references/spec-template.md",
        "skills/ralph-wiggum-loop/scripts/setup-ralph-loop.sh",
        "skills/ralph-wiggum-loop/scripts/start-http-server.sh",
        "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/hooks.json",
        "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/stop-hook.sh",
        "io.github.sheldonrobinson.ralph-wiggum-loop/commands/ralph-loop.md",
        "io.github.sheldonrobinson.ralph-wiggum-loop/commands/cancel-ralph.md",
        "io.github.sheldonrobinson.ralph-wiggum-loop/commands/help.md",
        "plugin.json",
        "LICENSE",
        "README.md"
    )
    foreach ($rel in $shFiles) {
        Copy-RelFile -SourceRoot $RepoRoot -StageRoot $stageSh -RelativePath $rel
    }

    $mcpbShPath = Join-Path $OutDir "ralph-wiggum-loop.sh.mcpb"
    New-McpbArchive -StageDir $stageSh -DestinationMcpb $mcpbShPath
    $sha256Sh = (Get-FileHash -LiteralPath $mcpbShPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # -------------------------------------------------------------------------
    # 2. Stage & Build ralph-wiggum-loop.pwsh.mcpb (PowerShell edition: win32)
    # -------------------------------------------------------------------------
    $stagePwsh = Join-Path $tempBase "pwsh"
    New-Item -ItemType Directory -Path $stagePwsh -Force | Out-Null

    $manifestPwshSrc = Join-Path $RepoRoot "packaging/mcpb/manifest.pwsh.json"
    $manifestPwshObj = Get-Content -LiteralPath $manifestPwshSrc -Raw | ConvertFrom-Json
    $manifestPwshObj.version = $Version
    [System.IO.File]::WriteAllText((Join-Path $stagePwsh "manifest.json"), (($manifestPwshObj | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)

    Write-PlatformMcpJson -TemplatePath $mcpTemplatePath -DestinationPath (Join-Path $stagePwsh "mcp.json") -TargetPlatform "pwsh"

    $pwshFiles = @(
        "bin/ralph-wiggum-loop.ps1",
        "bin/mcp-sdk.psm1",
        "bin/script-runner",
        "bin/script-runner.ps1",
        "bin/script-runner.cmd",
        "profiles/lite.json",
        "profiles/plus.json",
        "profiles/pro.json",
        "profiles/super.json",
        "profiles/ultra.json",
        "skills/ralph-wiggum-loop/SKILL.md",
        "skills/ralph-wiggum-loop/references/checklist.md",
        "skills/ralph-wiggum-loop/references/spec-template.md",
        "skills/ralph-wiggum-loop/scripts/setup-ralph-loop.ps1",
        "skills/ralph-wiggum-loop/scripts/start-http-server.ps1",
        "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/hooks.json",
        "io.github.sheldonrobinson.ralph-wiggum-loop/hooks/stop-hook.ps1",
        "io.github.sheldonrobinson.ralph-wiggum-loop/commands/ralph-loop.md",
        "io.github.sheldonrobinson.ralph-wiggum-loop/commands/cancel-ralph.md",
        "io.github.sheldonrobinson.ralph-wiggum-loop/commands/help.md",
        "plugin.json",
        "LICENSE",
        "README.md"
    )
    foreach ($rel in $pwshFiles) {
        Copy-RelFile -SourceRoot $RepoRoot -StageRoot $stagePwsh -RelativePath $rel
    }

    $mcpbPwshPath = Join-Path $OutDir "ralph-wiggum-loop.pwsh.mcpb"
    New-McpbArchive -StageDir $stagePwsh -DestinationMcpb $mcpbPwshPath
    $sha256Pwsh = (Get-FileHash -LiteralPath $mcpbPwshPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # -------------------------------------------------------------------------
    # 3. Generate Official MCP Registry server.json with both MCPB packages
    # -------------------------------------------------------------------------
    $releaseBase = "https://github.com/$RepoOwner/$RepoName/releases/download/v$Version"
    $serverJsonPath = Join-Path $RepoRoot "server.json"

    $serverManifest = [ordered]@{
        "`$schema"    = "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json"
        name          = "io.github.$RepoOwner/$RepoName"
        title         = "Ralph Wiggum Loop"
        description   = "Autonomous iterative AI development MCP server with spec-driven worker/reviewer SHIP/REVISE loops."
        version       = $Version
        websiteUrl    = "https://$RepoOwner.github.io/$RepoName"
        repository    = [ordered]@{
            url    = "https://github.com/$RepoOwner/$RepoName"
            source = "github"
        }
        packages      = @(
            [ordered]@{
                registryType         = "mcpb"
                identifier           = "$releaseBase/ralph-wiggum-loop.sh.mcpb"
                version              = $Version
                fileSha256           = $sha256Sh
                runtimeHint          = "sh"
                transport            = [ordered]@{
                    type = "stdio"
                }
                packageArguments     = @(
                    [ordered]@{
                        type        = "named"
                        name        = "--stdio"
                        description = "Run the POSIX sh MCP server over standard input/output (stdio)"
                    }
                )
                environmentVariables = @(
                    [ordered]@{
                        name        = "RALPH_STATE_BASE"
                        description = "Directory path where active Ralph Loop state and iteration history are stored"
                        isRequired  = $false
                    },
                    [ordered]@{
                        name        = "RALPH_RECIPE_DIR"
                        description = "Directory path containing workflow recipe JSON files"
                        isRequired  = $false
                    }
                )
            },
            [ordered]@{
                registryType         = "mcpb"
                identifier           = "$releaseBase/ralph-wiggum-loop.pwsh.mcpb"
                version              = $Version
                fileSha256           = $sha256Pwsh
                runtimeHint          = "pwsh"
                transport            = [ordered]@{
                    type = "stdio"
                }
                packageArguments     = @(
                    [ordered]@{
                        type        = "named"
                        name        = "-Stdio"
                        description = "Run the PowerShell MCP server over standard input/output (stdio)"
                    }
                )
                environmentVariables = @(
                    [ordered]@{
                        name        = "RALPH_STATE_BASE"
                        description = "Directory path where active Ralph Loop state and iteration history are stored"
                        isRequired  = $false
                    },
                    [ordered]@{
                        name        = "RALPH_RECIPE_DIR"
                        description = "Directory path containing workflow recipe JSON files"
                        isRequired  = $false
                    }
                )
            }
        )
    }

    $serverJsonContent = ($serverManifest | ConvertTo-Json -Depth 10) + "`n"
    [System.IO.File]::WriteAllText($serverJsonPath, $serverJsonContent, $utf8NoBom)

    Write-Output "Built Multi-Package MCPB Bundles (v$Version):"
    Write-Output "  [1] Bash MCPB (linux, darwin) : $mcpbShPath"
    Write-Output "      fileSha256                : $sha256Sh"
    Write-Output "  [2] PowerShell MCPB (win32)   : $mcpbPwshPath"
    Write-Output "      fileSha256                : $sha256Pwsh"
    Write-Output "  [3] MCP Registry              : $serverJsonPath"
} finally {
    if (Test-Path -LiteralPath $tempBase) {
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0
