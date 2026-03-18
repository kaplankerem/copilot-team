<#
.SYNOPSIS
    Installs KK-Orchestrator on the current machine.
.DESCRIPTION
    Copies orchestrator files to ~/.copilot-team/ and adds the `team` function
    to the user's PowerShell profile. After installation, open a new terminal
    and type `team` to launch the multi-agent environment.
.PARAMETER Force
    Overwrite existing installation without prompting.
#>

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoDir  = $PSScriptRoot
$baseDir  = "$env:USERPROFILE\.copilot-team"
$profilePath = "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"

Write-Host ""
Write-Host "  KK-Orchestrator Installer" -ForegroundColor Cyan
Write-Host "  =========================" -ForegroundColor Cyan
Write-Host ""

# --- Prerequisites ---
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

# Check PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "  [!] PowerShell 7+ (pwsh) is required. Install from: https://aka.ms/powershell" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

# Check Windows Terminal
$wt = Get-Command wt -ErrorAction SilentlyContinue
if (-not $wt) {
    Write-Host "  [!] Windows Terminal (wt) not found. Install from Microsoft Store." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Windows Terminal found" -ForegroundColor Green

# Check Copilot CLI
$copilot = Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue
if (-not $copilot) {
    # Try via gh
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        Write-Host "  [OK] GitHub CLI found (copilot available via 'gh copilot')" -ForegroundColor Green
    } else {
        Write-Host "  [!] GitHub Copilot CLI not found. Install from: https://gh.io/copilot-cli" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  [OK] Copilot CLI found" -ForegroundColor Green
}

# Check gh auth
try {
    $authStatus = gh auth status 2>&1
    if ($authStatus -match "Logged in") {
        Write-Host "  [OK] GitHub CLI authenticated" -ForegroundColor Green
    } else {
        Write-Host "  [!] GitHub CLI not authenticated. Run: gh auth login" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [!] Could not check GitHub auth status" -ForegroundColor Yellow
}

Write-Host ""

# --- Check existing installation ---
if ((Test-Path $baseDir) -and -not $Force) {
    Write-Host "Existing installation found at $baseDir" -ForegroundColor Yellow
    $response = Read-Host "Overwrite? (y/N)"
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Host "Cancelled." -ForegroundColor Red
        exit 0
    }
}

# --- Install files ---
Write-Host "Installing files..." -ForegroundColor Yellow

New-Item -ItemType Directory -Force "$baseDir\prompts"  | Out-Null
New-Item -ItemType Directory -Force "$baseDir\scripts"  | Out-Null
New-Item -ItemType Directory -Force "$baseDir\sessions" | Out-Null

Copy-Item "$repoDir\config.json" "$baseDir\config.json" -Force
Copy-Item "$repoDir\prompts\*.txt" "$baseDir\prompts\" -Force
Copy-Item "$repoDir\scripts\launch-team.ps1" "$baseDir\scripts\" -Force

Write-Host "  [OK] Files installed to $baseDir" -ForegroundColor Green

# --- Add team function to profile ---
Write-Host "Configuring PowerShell profile..." -ForegroundColor Yellow

# Ensure profile directory exists
$profileDir = Split-Path $profilePath -Parent
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Force $profileDir | Out-Null
}

# Create profile if it doesn't exist
if (-not (Test-Path $profilePath)) {
    "" | Set-Content $profilePath -Encoding UTF8
}

$profileContent = Get-Content $profilePath -Raw

if ($profileContent -match "function team") {
    Write-Host "  [OK] team function already in profile" -ForegroundColor Green
} else {
    $teamFunction = @"

function team {
    & "`$env:USERPROFILE\.copilot-team\scripts\launch-team.ps1"
}
"@
    Add-Content $profilePath $teamFunction -Encoding UTF8
    Write-Host "  [OK] Added team function to profile" -ForegroundColor Green
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Usage:" -ForegroundColor Cyan
Write-Host "    1. Open a new terminal (or run: . `$PROFILE)" -ForegroundColor White
Write-Host "    2. Type: team" -ForegroundColor White
Write-Host "    3. Type your task in the Orchestrator pane" -ForegroundColor White
Write-Host ""
