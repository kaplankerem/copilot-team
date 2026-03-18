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

# --- Auto-cleanup: remove sessions older than 7 days ---
$sessionsDir = Join-Path $baseDir "sessions"
if (Test-Path $sessionsDir) {
    $cutoff = (Get-Date).AddDays(-7)
    Get-ChildItem $sessionsDir -Directory | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force
        Write-Host "  Cleaned up old session: $($_.Name)" -ForegroundColor DarkGray
    }
}

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
`$mcpJson = Get-Content '$mcpConfigFile' -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10
`$PSNativeCommandArgumentPassing = 'Standard'
copilot --model $model --allow-all-tools $pathFlags --additional-mcp-config `$mcpJson -i `$prompt
"@ | Set-Content $launcherFile -Encoding UTF8
    } else {
        # Sub-agent launcher: watcher loop that launches copilot on-demand per task
        $inboxFile  = Join-Path $sessionDir "inbox\$agent.json"
        $outboxFile = Join-Path $sessionDir "outbox\$agent.json"
        @"
`$host.UI.RawUI.WindowTitle = '$title [$model]'
Write-Host ''
Write-Host '  $title' -ForegroundColor Cyan
Write-Host '  Model: $model' -ForegroundColor DarkGray
Write-Host '  Session: $sessionId' -ForegroundColor DarkGray
Write-Host ''

`$inboxFile  = '$inboxFile'
`$outboxFile = '$outboxFile'
`$promptFile = '$promptFile'
`$rolePrompt = Get-Content `$promptFile -Raw

Write-Host '  Watching inbox for tasks...' -ForegroundColor DarkGray
Write-Host ''

while (`$true) {
    try {
        `$raw = Get-Content `$inboxFile -Raw -ErrorAction SilentlyContinue
        if (`$raw -and `$raw.Trim() -ne '{}' -and `$raw.Trim() -ne '') {
            `$data = `$raw | ConvertFrom-Json -ErrorAction SilentlyContinue

            if (`$data.command -eq 'stop') {
                Write-Host '  [STOP] Received stop command.' -ForegroundColor Red
                '{"from":"$agent","status":"stopped"}' | Set-Content `$outboxFile -Encoding UTF8
                '{}' | Set-Content `$inboxFile -Encoding UTF8
            }
            elseif (`$data.command -eq 'cancel') {
                Write-Host '  [CANCEL] Task cancelled.' -ForegroundColor Yellow
                '{"from":"$agent","status":"cancelled"}' | Set-Content `$outboxFile -Encoding UTF8
                '{}' | Set-Content `$inboxFile -Encoding UTF8
            }
            elseif (`$data.task) {
                Write-Host ''
                Write-Host '  ============================================' -ForegroundColor Green
                Write-Host "  TASK RECEIVED at `$(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Green
                Write-Host '  ============================================' -ForegroundColor Green
                Write-Host ''

                # Build full prompt: role + task + output instructions
                `$taskPrompt = `$rolePrompt + "`n`n## YOUR CURRENT TASK`n" + `$data.task + "`n`n## CONTEXT`n" + `$data.context + "`n`n## OUTPUT INSTRUCTIONS`nWhen you have completed the task, write your results as JSON to this file:`n" + `$outboxFile + "`n`nUse Set-Content to write JSON to that path. The JSON must follow the format specified in your role prompt above.`nAfter writing your results, you are DONE — do not continue or poll for more tasks."
                `$taskFile = Join-Path '$sessionDir' "active_$agent.txt"
                `$taskPrompt | Set-Content `$taskFile -Encoding UTF8

                # Clear inbox before launching (so we don't re-trigger)
                '{}' | Set-Content `$inboxFile -Encoding UTF8

                # Launch copilot with a short -i that reads the full prompt from file (avoids command line length limit)
                copilot --model $model --allow-all-tools $pathFlags --no-ask-user -i "Read the file at '`$taskFile' and execute ALL instructions in it. Start by reading the file now."

                Write-Host ''
                Write-Host '  Task session ended. Watching for next task...' -ForegroundColor DarkGray
                Write-Host ''
            }
        }
    } catch {
        Write-Host "  Error: `$_" -ForegroundColor Red
    }
    Start-Sleep -Seconds 3
}
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
