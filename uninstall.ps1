<#
.SYNOPSIS
    Uninstalls KK-Orchestrator from the current machine.
.DESCRIPTION
    Removes ~/.copilot-team/ directory and the `team` function from the PowerShell profile.
#>

$ErrorActionPreference = "Stop"

$baseDir     = "$env:USERPROFILE\.copilot-team"
$profilePath = "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"

Write-Host ""
Write-Host "  KK-Orchestrator Uninstaller" -ForegroundColor Cyan
Write-Host ""

# --- Remove files ---
if (Test-Path $baseDir) {
    $response = Read-Host "Remove $baseDir and all sessions? (y/N)"
    if ($response -eq 'y' -or $response -eq 'Y') {
        Remove-Item $baseDir -Recurse -Force
        Write-Host "  [OK] Removed $baseDir" -ForegroundColor Green
    } else {
        Write-Host "  Skipped file removal." -ForegroundColor Yellow
    }
} else {
    Write-Host "  No installation found at $baseDir" -ForegroundColor Yellow
}

# --- Remove team function from profile ---
if (Test-Path $profilePath) {
    $content = Get-Content $profilePath -Raw
    if ($content -match "function team") {
        $newContent = $content -replace '(?m)\s*function team \{[^}]+\}\s*', "`n"
        $newContent = $newContent.TrimEnd() + "`n"
        Set-Content $profilePath $newContent -Encoding UTF8
        Write-Host "  [OK] Removed team function from profile" -ForegroundColor Green
    } else {
        Write-Host "  team function not found in profile" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Uninstall complete. Restart your terminal to apply." -ForegroundColor Green
Write-Host ""
