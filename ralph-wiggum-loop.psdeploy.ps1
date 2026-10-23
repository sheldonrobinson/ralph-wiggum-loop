# PSDeploy deployment configuration (https://github.com/RamblingCookieMonster/PSDeploy)
# Installs the complete Agent Plugin to $HOME\.agents\ralph-wiggum-loop
# and mirrors the Agent Skill to $HOME\.agents\skills\ralph-wiggum-loop
# Usage: Invoke-PSDeploy -Path .\ralph-wiggum-loop.psdeploy.ps1 -Force

Deploy RalphWiggumLoop {
    By FileSystem PluginManifests {
        FromSource 'plugin.json', 'mcp.json', 'server.json', 'README.md', 'LICENSE'
        To "$HOME\.agents\ralph-wiggum-loop"
    }

    By FileSystem Scripts {
        FromSource 'bin'
        To "$HOME\.agents\ralph-wiggum-loop\bin"
        WithOptions @{
            Mirror = $true
        }
    }

    By FileSystem Profiles {
        FromSource 'profiles'
        To "$HOME\.agents\ralph-wiggum-loop\profiles"
        WithOptions @{
            Mirror = $true
        }
    }

    By FileSystem PluginSkills {
        FromSource 'skills\ralph-wiggum-loop'
        To "$HOME\.agents\ralph-wiggum-loop\skills\ralph-wiggum-loop"
        WithOptions @{
            Mirror = $true
        }
    }

    By FileSystem CanonicalAgentSkills {
        FromSource 'skills\ralph-wiggum-loop'
        To "$HOME\.agents\skills\ralph-wiggum-loop"
        WithOptions @{
            Mirror = $true
        }
    }

    By FileSystem HooksAndCommands {
        FromSource 'io.github.sheldonrobinson.ralph-wiggum-loop'
        To "$HOME\.agents\ralph-wiggum-loop\io.github.sheldonrobinson.ralph-wiggum-loop"
        WithOptions @{
            Mirror = $true
        }
    }
}
