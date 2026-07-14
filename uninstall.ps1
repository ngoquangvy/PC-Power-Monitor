param(
    [switch]$KeepData,
    [switch]$Purge,
    [switch]$RemoveConfig,
    [switch]$NoElevation
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$StagingConfigPath = Join-Path $ScriptDir "config.json"
$LegacyConfigPath = Join-Path $ScriptDir "config.ps1"

if ($KeepData -and $Purge) {
    throw "Use either -KeepData or -Purge, not both. Runtime data is removed by default; -Purge is kept for backward compatibility."
}

$RemoveRuntimeData = (-not $KeepData) -or $Purge
$RemoveEffectiveConfig = $RemoveConfig -or $RemoveRuntimeData

if (-not (Test-TelegramLogAdmin)) {
    if ($NoElevation) {
        throw "Administrator rights are required to remove all Scheduled Tasks."
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-NoElevation"
    )
    if ($KeepData) { $arguments += "-KeepData" }
    if ($Purge) { $arguments += "-Purge" }
    if ($RemoveConfig) { $arguments += "-RemoveConfig" }

    Write-Host "Requesting administrator permission..."
    $process = Start-Process -FilePath $PowerShell -ArgumentList ($arguments -join " ") -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

Stop-TelegramLogTray -ScriptDir $ScriptDir
Remove-TelegramLogTasks
Stop-TelegramLogProcesses -ScriptDir $ScriptDir

if ($RemoveRuntimeData) {
    $logDirectory = Get-TelegramLogDirectory -ScriptDir $ScriptDir
    if (Test-Path -LiteralPath $logDirectory) {
        $resolvedRoot = [IO.Path]::GetFullPath($ScriptDir)
        $expectedLogs = [IO.Path]::GetFullPath((Join-Path $resolvedRoot "logs"))
        $actualLogs = [IO.Path]::GetFullPath($logDirectory)
        if (-not $actualLogs.Equals($expectedLogs, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove log directory outside the app folder: $actualLogs"
        }
        Remove-Item -LiteralPath $actualLogs -Recurse -Force
    }

    foreach ($dataFile in @("state.json", "state.json.tmp")) {
        Remove-Item -LiteralPath (Join-Path $ScriptDir $dataFile) -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $ScriptDir -File -Filter "boot-log*.txt" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $ScriptDir -File -Filter "telegram-send-*.py" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $TelegramLogRuntimeDir) {
        $expectedRuntime = [IO.Path]::GetFullPath((Join-Path $env:ProgramData "TelegramPowerMonitor"))
        $actualRuntime = [IO.Path]::GetFullPath($TelegramLogRuntimeDir)
        if (-not $actualRuntime.Equals($expectedRuntime, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove runtime directory outside ProgramData: $actualRuntime"
        }
        Remove-Item -LiteralPath $actualRuntime -Recurse -Force
    }
}

if ($RemoveEffectiveConfig) {
    Remove-Item -LiteralPath $TelegramLogConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StagingConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LegacyConfigPath -Force -ErrorAction SilentlyContinue
}
foreach ($markerName in @($TelegramLogConfigMarkerName) + @($TelegramLogLegacyConfigMarkerNames)) {
    Remove-Item -LiteralPath (Join-Path $ScriptDir $markerName) -Force -ErrorAction SilentlyContinue
}

$remaining = @(Get-TelegramLogRemainingArtifacts -ScriptDir $ScriptDir -IncludeData:$RemoveRuntimeData -IncludeConfig:$RemoveEffectiveConfig)
if ($remaining.Count -gt 0) {
    Write-Host "Uninstall is incomplete. Remaining artifacts:" -ForegroundColor Red
    $remaining | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "Uninstall verification failed."
}

Write-Host "Uninstall completed and verified."
Write-Host "Removed all Scheduled Tasks (including legacy names), running monitor processes, Startup shortcuts, wrappers, and ProgramData runtime files."
if ($RemoveRuntimeData) {
    Write-Host "Removed generated state, temporary files, and local logs."
} else {
    Write-Host "Kept generated state and logs because -KeepData was specified."
}
if ($RemoveEffectiveConfig) {
    Write-Host "Removed Telegram settings and credentials."
} else {
    Write-Host "Kept Telegram settings because -KeepData was specified. Use -RemoveConfig to delete settings while keeping logs."
}
