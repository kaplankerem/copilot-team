<#
.SYNOPSIS
    Launches a multi-agent Copilot CLI team in Windows Terminal split panes.
.DESCRIPTION
    Creates a session with inbox/outbox directories, generates per-agent launcher
    scripts with injected prompts, and opens Windows Terminal with 6 panes.
    Each pane runs a full interactive Copilot CLI TUI.
#>

$ErrorActionPreference = "Stop"

$baseDir    = "$env:USERPROFILE\.copilot-team"
$configFile = Join-Path $baseDir "config.json"
$promptsDir = Join-Path $baseDir "prompts"

# --- Load config ---
$config = Get-Content $configFile -Raw | ConvertFrom-Json

# --- Create session ---
$sessionId  = [guid]::NewGuid().ToString().Substring(0, 8)
$sessionDir = Join-Path $baseDir "sessions\$sessionId"
New-Item -ItemType Directory -Force "$sessionDir\inbox"  | Out-Null
New-Item -ItemType Directory -Force "$sessionDir\outbox" | Out-Null

# Initialize empty inbox files
$agents = @("orchestrator", "frontend", "backend", "pm", "qa", "devops")
foreach ($agent in $agents) {
    "{}" | Set-Content "$sessionDir\inbox\$agent.json" -Encoding UTF8
}

# Initialize state
@{
    session_id = $sessionId
    created_at = (Get-Date -Format "o")
    status     = "active"
} | ConvertTo-Json | Set-Content "$sessionDir\state.json" -Encoding UTF8

Write-Host "Session: $sessionId" -ForegroundColor Cyan
Write-Host "Directory: $sessionDir" -ForegroundColor DarkGray
Write-Host ""

# --- Ask user for path access level ---
Write-Host "  Path Access Mode" -ForegroundColor Yellow
Write-Host "  [1] Session directory only (secure — agents can only access session files)"
Write-Host "  [2] Allow all paths (full filesystem access — needed for working on existing projects)"
Write-Host ""
$choice = Read-Host "  Select (1 or 2)"

if ($choice -eq "2") {
    $pathFlags = "--allow-all-paths"
    Write-Host "  -> Full filesystem access enabled" -ForegroundColor Red
} else {
    $pathFlags = "--add-dir `"$sessionDir`""
    Write-Host "  -> Scoped to session directory" -ForegroundColor Green
}
Write-Host ""

# --- Generate MCP config for orchestrator ---
$mcpServerDir = Join-Path $baseDir "mcp-server"
$mcpConfigFile = Join-Path $sessionDir "mcp-config.json"
@{
    mcpServers = @{
        "team-orchestrator" = @{
            type    = "stdio"
            command = "node"
            args    = @((Join-Path $mcpServerDir "server.js"))
            env     = @{
                TEAM_SESSION_DIR = $sessionDir
            }
        }
    }
} | ConvertTo-Json -Depth 5 | Set-Content $mcpConfigFile -Encoding UTF8

# --- Generate per-agent launcher scripts ---
foreach ($agent in $agents) {
    $agentConfig = $config.agents.$agent
    $model = $agentConfig.model
    $title = "$($agentConfig.emoji) $($agentConfig.title)"

    # Read prompt template and inject session path
    $promptText = Get-Content (Join-Path $promptsDir "$agent.txt") -Raw
    $promptText = $promptText.Replace("{SESSION}", $sessionDir)

    # Write injected prompt to session dir
    $promptFile = Join-Path $sessionDir "prompt_$agent.txt"
    $promptText | Set-Content $promptFile -Encoding UTF8

    # Orchestrator keeps ask_user (needs to interact with user); workers get --no-ask-user
    $askUserFlag = if ($agent -eq "orchestrator") { "" } else { "--no-ask-user " }

    # Orchestrator uses MCP server for delegation (no --experimental to prevent background tasks)
    # Sub-agents use --experimental for autopilot polling
    $experimentalFlag = if ($agent -eq "orchestrator") { "" } else { "--experimental " }

    # Write small launcher script
    $launcherFile = Join-Path $sessionDir "launch_$agent.ps1"

    if ($agent -eq "orchestrator") {
        # Orchestrator launcher: reads MCP config JSON inline at runtime
        @"
`$host.UI.RawUI.WindowTitle = '$title [$model]'
Write-Host ''
Write-Host '  $title' -ForegroundColor Cyan
Write-Host '  Model: $model' -ForegroundColor DarkGray
Write-Host '  Session: $sessionId' -ForegroundColor DarkGray
Write-Host ''
`$promptFile = '$promptFile'
`$prompt = Get-Content `$promptFile -Raw
`$mcpJson = (Get-Content '$mcpConfigFile' -Raw) -replace '\r?\n', ' '
copilot --model $model --allow-all-tools $pathFlags --additional-mcp-config `$mcpJson -i `$prompt
"@ | Set-Content $launcherFile -Encoding UTF8
    } else {
        # Sub-agent launcher: experimental mode for autopilot polling
        @"
`$host.UI.RawUI.WindowTitle = '$title [$model]'
Write-Host ''
Write-Host '  $title' -ForegroundColor Cyan
Write-Host '  Model: $model' -ForegroundColor DarkGray
Write-Host '  Session: $sessionId' -ForegroundColor DarkGray
Write-Host ''
`$promptFile = '$promptFile'
`$prompt = Get-Content `$promptFile -Raw
copilot --model $model --experimental --allow-all-tools $pathFlags --no-ask-user -i `$prompt
"@ | Set-Content $launcherFile -Encoding UTF8
    }
}

# --- Build Windows Terminal command via .cmd file (avoids PS escaping issues) ---
# Layout: 2 rows x 3 columns
#   Row 1: orchestrator | frontend | backend
#   Row 2: pm           | qa       | devops

function Get-PaneCmd($agent) {
    $launcher = Join-Path $sessionDir "launch_$agent.ps1"
    return "pwsh -NoExit -File `"$launcher`""
}

$cmdOrch     = Get-PaneCmd 'orchestrator'
$cmdFrontend = Get-PaneCmd 'frontend'
$cmdBackend  = Get-PaneCmd 'backend'
$cmdPm       = Get-PaneCmd 'pm'
$cmdQa       = Get-PaneCmd 'qa'
$cmdDevops   = Get-PaneCmd 'devops'

# Write a .cmd file with the full wt command — no PowerShell escaping needed
$wtBatchFile = Join-Path $sessionDir "launch.cmd"
@"
@echo off
wt new-tab --title "ORCHESTRATOR" --tabColor "$($config.agents.orchestrator.tabColor)" $cmdOrch ; ^
split-pane -H --size 0.67 --title "FRONTEND" $cmdFrontend ; ^
split-pane -H --size 0.5 --title "BACKEND" $cmdBackend ; ^
move-focus first ; ^
split-pane -V --size 0.5 --title "PM" $cmdPm ; ^
move-focus right ; ^
split-pane -V --size 0.5 --title "QA-TEST" $cmdQa ; ^
move-focus right ; ^
split-pane -V --size 0.5 --title "DEVOPS" $cmdDevops ; ^
move-focus first
"@ | Set-Content $wtBatchFile -Encoding ASCII

Write-Host ""
Write-Host "Launching team..." -ForegroundColor Green
Write-Host "Orchestrator pane will be focused - type your task there." -ForegroundColor Yellow
Write-Host ""

# Launch via the batch file
& cmd.exe /c $wtBatchFile
