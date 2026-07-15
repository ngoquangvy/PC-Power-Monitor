$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

Show-TelegramLogStatus

$ConfigPath = Get-TelegramLogConfigCandidate -ScriptDir $ScriptDir
try {
    [void](Read-TelegramLogConfig -Path $ConfigPath)
    $configLocation = if ([IO.Path]::GetFullPath($ConfigPath).Equals([IO.Path]::GetFullPath($TelegramLogConfigPath), [StringComparison]::OrdinalIgnoreCase)) { "installed (secured ProgramData)" } else { "staging (will move during install)" }
    Write-Host ""
    Write-Host "Telegram settings: configured; $configLocation"
} catch {
    Write-Host ""
    Write-Host "Telegram settings: missing or invalid" -ForegroundColor Yellow
}

$StatePath = Join-Path $ScriptDir "state.json"
if (Test-Path -LiteralPath $StatePath) {
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        Write-Host ""
        Write-Host "Notification state:"
        Write-Host "  Internet online: $($state.internetOnline)"
        Write-Host "  Last monitor-start notification: $($state.lastMonitorStartNotificationAt)"
        Write-Host "  Last startup notification: $($state.lastStartupNotificationAt)"
        Write-Host "  Last resume notification: $($state.lastResumeNotificationAt)"
        Write-Host "  Last resume event ID: $($state.lastNotifiedResumeEventId)"
        Write-Host "  Last pre-sleep notification: $($state.lastPreSleepNotificationAt)"
        Write-Host "  Last successful send: $($state.lastSuccessfulSend)"
        Write-Host "  Last state check: $($state.lastCheckAt)"
    } catch {
        Write-Host ""
        Write-Host "State: could not read state.json"
    }
}

$LogDirectory = Get-TelegramLogDirectory -ScriptDir $ScriptDir
if (Test-Path -LiteralPath $LogDirectory) {
    $lastSuspendAudit = Get-ChildItem -LiteralPath $LogDirectory -File -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern "SUSPEND_AUDIT Sequence=" -ErrorAction SilentlyContinue | Select-Object -Last 1 } |
        Select-Object -First 1
    Write-Host ""
    if ($lastSuspendAudit) {
        Write-Host "Last suspend verification: $($lastSuspendAudit.Line)"
    } else {
        Write-Host "Last suspend verification: none recorded yet"
    }

    $latestLog = Get-ChildItem -LiteralPath $LogDirectory -File -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) {
        Write-Host ""
        Write-Host "Recent local log ($($latestLog.Name)):"
        Get-Content -LiteralPath $latestLog.FullName -Tail 12
    }
}
