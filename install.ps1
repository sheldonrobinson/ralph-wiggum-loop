#Requires -Version 5.1

<#
.SYNOPSIS
Installs ralph-wiggum-loop with native PowerShell file operations.

.DESCRIPTION
Copies the plugin to $HOME\.agents\ralph-wiggum-loop and a self-contained
canonical Agent Skill to $HOME\.agents\skills\ralph-wiggum-loop. Both receive
the bin, profiles, and hook runtime required by SKILL.md. Managed directories
are mirrored so repeated installs update files and remove stale content.

.PARAMETER SourceRoot
Repository root containing the files to install. Defaults to this script's
directory.

.PARAMETER AgentsRoot
Base .agents directory. Defaults to $HOME\.agents.

.PARAMETER PluginRoot
Optional full plugin destination. Overrides the default below AgentsRoot.

.PARAMETER SkillRoot
Optional full canonical skill destination. Overrides the default below
AgentsRoot.

.EXAMPLE
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
pwsh -NoProfile -File .\install.ps1 -AgentsRoot C:\Temp\ralph-agents

Installs both destinations below a temporary root for validation.
#>

[CmdletBinding()]
param(
    [string]$SourceRoot = $PSScriptRoot,
    [string]$AgentsRoot = (Join-Path -Path $HOME -ChildPath '.agents'),
    [string]$PluginRoot,
    [string]$SkillRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Remove-TrailingSeparator {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $Path.TrimEnd([char[]]@('\', '/'))
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $child = Remove-TrailingSeparator -Path ([IO.Path]::GetFullPath($Path))
    $base = Remove-TrailingSeparator -Path ([IO.Path]::GetFullPath($Parent))
    $comparison = [StringComparison]::OrdinalIgnoreCase

    if ($child.Equals($base, $comparison)) {
        return $true
    }

    return $child.StartsWith($base + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-NotFileSystemRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [IO.Path]::GetPathRoot($Path)
    if ((Remove-TrailingSeparator -Path $Path).Equals(
            (Remove-TrailingSeparator -Path $root),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use filesystem root as a managed destination: $Path"
    }
}

function Assert-SafeDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-NotFileSystemRoot -Path $Destination

    if ((Test-PathWithin -Path $Destination -Parent $Source) -or
        (Test-PathWithin -Path $Source -Parent $Destination)) {
        throw "Source and managed destination must not overlap: $Source <-> $Destination"
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $base = Remove-TrailingSeparator -Path ([IO.Path]::GetFullPath($BasePath))
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $base + [IO.Path]::DirectorySeparatorChar

    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside its expected base directory: $full"
    }

    return $full.Substring($prefix.Length)
}

function Copy-DirectoryMirror {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourcePath = ConvertTo-FullPath -Path $Source
    $destinationPath = ConvertTo-FullPath -Path $Destination

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Required source directory not found: $sourcePath"
    }

    Assert-SafeDestination -Source $sourcePath -Destination $destinationPath
    $null = New-Item -ItemType Directory -Path $destinationPath -Force

    $sourceDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sourceFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($directory in @(Get-ChildItem -LiteralPath $sourcePath -Force -Recurse -Directory)) {
        $relativePath = Get-RelativePath -BasePath $sourcePath -Path $directory.FullName
        $null = $sourceDirectories.Add($relativePath)
        $targetDirectory = Join-Path -Path $destinationPath -ChildPath $relativePath
        $null = New-Item -ItemType Directory -Path $targetDirectory -Force
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $sourcePath -Force -Recurse -File)) {
        $relativePath = Get-RelativePath -BasePath $sourcePath -Path $file.FullName
        $null = $sourceFiles.Add($relativePath)
        $targetPath = Join-Path -Path $destinationPath -ChildPath $relativePath
        $targetDirectory = Split-Path -Path $targetPath -Parent
        $null = New-Item -ItemType Directory -Path $targetDirectory -Force
        Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $destinationPath -Force -Recurse -File)) {
        $relativePath = Get-RelativePath -BasePath $destinationPath -Path $file.FullName
        if (-not $sourceFiles.Contains($relativePath)) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }

    $extraDirectories = @(
        Get-ChildItem -LiteralPath $destinationPath -Force -Recurse -Directory |
            Sort-Object -Property { $_.FullName.Length } -Descending
    )
    foreach ($directory in $extraDirectories) {
        $relativePath = Get-RelativePath -BasePath $destinationPath -Path $directory.FullName
        if (-not $sourceDirectories.Contains($relativePath)) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        }
    }

    Write-Verbose "Mirrored $sourcePath to $destinationPath"
}

$sourcePath = ConvertTo-FullPath -Path $SourceRoot
$agentsPath = ConvertTo-FullPath -Path $AgentsRoot

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "Source root not found: $sourcePath"
}

if ([string]::IsNullOrWhiteSpace($PluginRoot)) {
    $PluginRoot = Join-Path -Path $agentsPath -ChildPath 'ralph-wiggum-loop'
}
if ([string]::IsNullOrWhiteSpace($SkillRoot)) {
    $SkillRoot = Join-Path -Path $agentsPath -ChildPath 'skills\ralph-wiggum-loop'
}

$pluginPath = ConvertTo-FullPath -Path $PluginRoot
$skillPath = ConvertTo-FullPath -Path $SkillRoot
Assert-NotFileSystemRoot -Path $pluginPath
Assert-NotFileSystemRoot -Path $skillPath

if ((Test-PathWithin -Path $pluginPath -Parent $skillPath) -or
    (Test-PathWithin -Path $skillPath -Parent $pluginPath)) {
    throw 'PluginRoot and SkillRoot must be separate, non-nested destinations.'
}

foreach ($manifestName in @('plugin.json', 'mcp.json', 'server.json')) {
    $manifestPath = Join-Path -Path $sourcePath -ChildPath $manifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Required source manifest not found: $manifestPath"
    }
    $null = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

$null = New-Item -ItemType Directory -Path $pluginPath -Force
foreach ($fileName in @('plugin.json', 'mcp.json', 'server.json', 'README.md', 'LICENSE')) {
    $filePath = Join-Path -Path $sourcePath -ChildPath $fileName
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Required source file not found: $filePath"
    }
    Copy-Item -LiteralPath $filePath -Destination (Join-Path -Path $pluginPath -ChildPath $fileName) -Force
}

$directoryMappings = @(
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'bin'
        Destination = Join-Path -Path $pluginPath -ChildPath 'bin'
    },
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'profiles'
        Destination = Join-Path -Path $pluginPath -ChildPath 'profiles'
    },
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'skills\ralph-wiggum-loop'
        Destination = Join-Path -Path $pluginPath -ChildPath 'skills\ralph-wiggum-loop'
    },
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'skills\ralph-wiggum-loop'
        Destination = $skillPath
    },
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'io.github.sheldonrobinson.ralph-wiggum-loop'
        Destination = Join-Path -Path $pluginPath -ChildPath 'io.github.sheldonrobinson.ralph-wiggum-loop'
    },
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'bin'
        Destination = Join-Path -Path $skillPath -ChildPath 'bin'
    },
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'profiles'
        Destination = Join-Path -Path $skillPath -ChildPath 'profiles'
    },
    @{
        Source = Join-Path -Path $sourcePath -ChildPath 'io.github.sheldonrobinson.ralph-wiggum-loop'
        Destination = Join-Path -Path $skillPath -ChildPath 'io.github.sheldonrobinson.ralph-wiggum-loop'
    }
)

foreach ($mapping in $directoryMappings) {
    Copy-DirectoryMirror -Source $mapping.Source -Destination $mapping.Destination
}

[pscustomobject]@{
    PluginRoot = $pluginPath
    SkillRoot = $skillPath
}
