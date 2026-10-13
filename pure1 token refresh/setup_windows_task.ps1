# =============================================================================
# setup_windows_task.ps1
# Registers a Windows Scheduled Task to auto-refresh the Pure1 API token
# every 9 hours — the Windows equivalent of the macOS LaunchAgent plist.
#
# Run once to install. The task fires immediately on registration and then
# repeats every 9 hours indefinitely.
#
# Usage (run as your normal user, NOT as Administrator):
#   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#   .\setup_windows_task.ps1
#
# Manage the task afterwards:
#   Start-ScheduledTask  -TaskName "Pure1TokenRefresh"   # run now
#   Get-ScheduledTask    -TaskName "Pure1TokenRefresh"   # view status
#   Unregister-ScheduledTask -TaskName "Pure1TokenRefresh" -Confirm:$false  # remove
# =============================================================================

$ErrorActionPreference = "Stop"

$TaskName   = "Pure1TokenRefresh"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $ScriptDir "refresh_pure1_token.ps1"

Write-Host "Setting up Windows Scheduled Task: $TaskName"
Write-Host "Script path: $ScriptPath"

if (-not (Test-Path $ScriptPath)) {
    Write-Error "refresh_pure1_token.ps1 not found at $ScriptPath. Aborting."
    exit 1
}

# ── Task Action ───────────────────────────────────────────────────────────────
# Use pwsh (PowerShell 7+) if available, fall back to powershell.exe (5.x)
$PwshPath = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    (Get-Command pwsh).Source
} else {
    "powershell.exe"
}

$Action = New-ScheduledTaskAction `
    -Execute $PwshPath `
    -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""

# ── Trigger: run once now, then repeat every 9 hours indefinitely ─────────────
# Omitting -RepetitionDuration means "indefinitely". [TimeSpan]::MaxValue is
# rejected as out of range by Task Scheduler on current Windows versions.
$Trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Hours 9)

# ── Settings ──────────────────────────────────────────────────────────────────
#   StartWhenAvailable        run as soon as possible if a scheduled run was missed
#   RunOnlyIfNetworkAvailable skip if offline (token exchange requires internet)
#   MultipleInstances         don't stack concurrent runs
# (A backtick continuation must end the line, so these can't be inline comments.)
$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -MultipleInstances IgnoreNew

# ── Principal: run as the current logged-in user (not SYSTEM) ─────────────────
# Running as the current user ensures the User-scope registry env var is set
# for the correct account (not the SYSTEM account).
$Principal = New-ScheduledTaskPrincipal `
    -UserId    $env:USERNAME `
    -LogonType Interactive `
    -RunLevel  Limited

# ── Register ──────────────────────────────────────────────────────────────────
Register-ScheduledTask `
    -TaskName   $TaskName `
    -Action     $Action `
    -Trigger    $Trigger `
    -Settings   $Settings `
    -Principal  $Principal `
    -Description "Refreshes the Pure1 API Bearer token every 9 hours and sets PURE1_ACCESS_TOKEN in the User environment." `
    -Force | Out-Null

Write-Host ""
Write-Host "Scheduled task '$TaskName' registered successfully."
Write-Host ""
Write-Host "It will run immediately and then every 9 hours."
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Start now : Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  View      : Get-ScheduledTask    -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "  Remove    : Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
