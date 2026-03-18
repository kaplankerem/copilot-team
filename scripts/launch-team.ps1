<#
.SYNOPSIS
    Launches the orchestrator — a single Copilot CLI TUI that delegates to background agents.
.DESCRIPTION
    Creates a session directory, generates MCP config for the team-orchestrator server,
    and launches a single interactive Copilot CLI session. Sub-agents run as headless
    background processes spawned by the MCP server.
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

# Initialize state
@{
    session_id = $sessionId
    created_at = (Get-Date -Format "o")
    status     = "active"
} | ConvertTo-Json | Set-Content "$sessionDir\state.json" -Encoding UTF8

Write-Host ""
Write-Host "  🧠 TEAM ORCHESTRATOR" -ForegroundColor Cyan
Write-Host "  Session: $sessionId" -ForegroundColor DarkGray
Write-Host "  Directory: $sessionDir" -ForegroundColor DarkGray

# Show agent models
Write-Host ""
Write-Host "  Agent Models:" -ForegroundColor Yellow
$agents = @("frontend", "backend", "pm", "qa", "devops")
foreach ($a in $agents) {
    $m = $config.agents.$a.model
    $e = $config.agents.$a.emoji
    Write-Host "    $e $($a.PadRight(10)) → $m" -ForegroundColor DarkGray
}
Write-Host ""

# --- Ask user for path access level ---
Write-Host "  Path Access Mode" -ForegroundColor Yellow
Write-Host "  [1] Session directory only (secure)"
Write-Host "  [2] Allow all paths (needed for working on existing projects)"
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

# --- Generate MCP config ---
$mcpServerDir = Join-Path $baseDir "mcp-server"
$mcpConfigFile = Join-Path $sessionDir "mcp-config.json"
@{
    mcpServers = @{
        "team-orchestrator" = @{
            type    = "stdio"
            command = "node"
            args    = @((Join-Path $mcpServerDir "server.js"))
            env     = @{
                TEAM_SESSION_DIR  = $sessionDir
                TEAM_CONFIG_FILE  = $configFile
                TEAM_PROMPTS_DIR  = $promptsDir
                TEAM_PATH_FLAGS   = $pathFlags
            }
        }
    }
} | ConvertTo-Json -Depth 5 | Set-Content $mcpConfigFile -Encoding UTF8

# --- Read orchestrator prompt ---
$orchModel = $config.agents.orchestrator.model
$promptText = Get-Content (Join-Path $promptsDir "orchestrator.txt") -Raw
$promptText = $promptText.Replace("{SESSION}", $sessionDir)
$promptFile = Join-Path $sessionDir "prompt_orchestrator.txt"
$promptText | Set-Content $promptFile -Encoding UTF8

# --- Launch orchestrator ---
Write-Host "  Launching orchestrator..." -ForegroundColor Green
Write-Host "  Type your task below. Agents will work in the background." -ForegroundColor Yellow
Write-Host ""

$mcpJson = Get-Content $mcpConfigFile -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10
$PSNativeCommandArgumentPassing = 'Standard'
copilot --model $orchModel --allow-all-tools $pathFlags --additional-mcp-config $mcpJson -i "Read the file at '$promptFile' and follow ALL instructions in it. You are the orchestrator. Wait for the user to describe what they want to build."
