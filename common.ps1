$TelegramLogTaskNames = @(
    "TelegramPowerMonitor-OnStartup",
    "TelegramPowerMonitor-OnResume",
    "TelegramPowerMonitor-Watcher"
)

# Names from older releases are kept here so repair/uninstall also removes them.
$TelegramLogLegacyTaskNames = @(
    "TelegramIdleMonitor-IdleCheck",
    "TelegramIdleMonitor-BeforeSleep",
    "TelegramIdleMonitor-OnResume",
    "TelegramBootLog-OnStartup",
    "TelegramBootLog-OnResume",
    "TelegramBootLog-BeforeSleep",
    "TelegramBootLog-Heartbeat",
    "TelegramPowerMonitor-OnSleepTransition"
)

$TelegramLogRuntimeDir = Join-Path $env:ProgramData "TelegramPowerMonitor"
$TelegramLogConfigPath = Join-Path $TelegramLogRuntimeDir "config.json"
$TelegramLogLegacyRuntimeDirs = @(
    (Join-Path $env:ProgramData "TelegramIdleMonitor")
)
$TelegramLogWrapperPaths = @()

$TelegramLogLegacyWrapperPaths = @(
    (Join-Path $env:ProgramData "TelegramIdleMonitor\run-hidden.vbs"),
    (Join-Path $env:ProgramData "TelegramIdleMonitor\idle-check.cmd"),
    (Join-Path $env:ProgramData "TelegramIdleMonitor\before-sleep.cmd"),
    (Join-Path $env:ProgramData "TelegramIdleMonitor\resume.cmd"),
    "C:\tmp\telegramlog-startup.cmd",
    "C:\tmp\telegramlog-resume.cmd",
    "C:\tmp\telegramlog-before-sleep.cmd",
    "C:\tmp\telegramlog-heartbeat.cmd"
)

$TelegramLogStartupShortcutName = "Telegram Power Monitor.lnk"
$TelegramLogLegacyShortcutNames = @("Telegram Idle Monitor.lnk", "Telegram Startup Monitor Tray.lnk")
$TelegramLogConfigMarkerName = ".telegram-power-monitor-config-created"
$TelegramLogLegacyConfigMarkerNames = @(".telegram-idle-monitor-config-created")

function Test-TelegramLogAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TelegramLogDirectory {
    param([string]$ScriptDir)

    return (Join-Path $ScriptDir "logs")
}

function Get-TelegramLogConfigCandidate {
    param([string]$ScriptDir)

    if (Test-Path -LiteralPath $TelegramLogConfigPath) {
        return $TelegramLogConfigPath
    }
    $stagingPath = Join-Path $ScriptDir "config.json"
    if (Test-Path -LiteralPath $stagingPath) {
        return $stagingPath
    }
    return $null
}

function Read-TelegramLogConfig {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw "Telegram configuration was not found."
    }
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$config.telegramBotToken)) {
        throw "Telegram bot token is missing."
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.telegramChatId)) {
        throw "Telegram chat ID is missing."
    }
    if ([string]$config.telegramBotToken -notmatch '^\d{6,15}:[A-Za-z0-9_-]{20,}$') {
        throw "Telegram bot token is not in the expected format."
    }
    if ([string]$config.telegramChatId -notmatch '^-?\d+$' -and [string]$config.telegramChatId -notmatch '^@[A-Za-z][A-Za-z0-9_]{4,31}$') {
        throw "Telegram chat ID is not in the expected format."
    }
    return [pscustomobject]@{
        TelegramBotToken = [string]$config.telegramBotToken
        TelegramChatId = [string]$config.telegramChatId
    }
}

function Remove-TelegramLogOldLogs {
    param(
        [string]$ScriptDir,
        [ValidateRange(1, 365)]
        [int]$RetentionDays = 5
    )

    $logDirectory = Get-TelegramLogDirectory -ScriptDir $ScriptDir
    # Include today in the retention window (5 means today plus the previous 4 days).
    $cutoff = (Get-Date).Date.AddDays(1 - $RetentionDays)
    if (Test-Path -LiteralPath $logDirectory) {
        Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Clean legacy flat log files left by older releases as well.
    Get-ChildItem -LiteralPath $ScriptDir -File -Filter "boot-log*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-TelegramLog {
    param(
        [string]$ScriptDir,
        [string]$Message,
        [ValidateRange(1, 365)]
        [int]$RetentionDays = 5
    )

    $logDirectory = Get-TelegramLogDirectory -ScriptDir $ScriptDir
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    Remove-TelegramLogOldLogs -ScriptDir $ScriptDir -RetentionDays $RetentionDays

    $logPath = Join-Path $logDirectory ("monitor-{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"), $Message
    $mutex = New-Object System.Threading.Mutex($false, "Local\TelegramIdleMonitorLog")
    try {
        if ($mutex.WaitOne(5000)) {
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        }
    } finally {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}

function Remove-TelegramLogTasks {
    foreach ($task in @($TelegramLogTaskNames) + @($TelegramLogLegacyTaskNames)) {
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & schtasks.exe /End /TN $task 2>&1 | Out-Null
        & schtasks.exe /Delete /TN $task /F 2>&1 | Out-Null
        $ErrorActionPreference = $oldErrorActionPreference
    }

    foreach ($wrapper in @($TelegramLogWrapperPaths) + @($TelegramLogLegacyWrapperPaths)) {
        Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
    }

    foreach ($legacyRuntime in $TelegramLogLegacyRuntimeDirs) {
        if (Test-Path -LiteralPath $legacyRuntime) {
            $expectedRuntime = [IO.Path]::GetFullPath((Join-Path $env:ProgramData "TelegramIdleMonitor"))
            $actualRuntime = [IO.Path]::GetFullPath($legacyRuntime)
            if ($actualRuntime.Equals($expectedRuntime, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $actualRuntime -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $startupFolder = [Environment]::GetFolderPath("Startup")
    if ($startupFolder) {
        foreach ($shortcutName in @($TelegramLogStartupShortcutName) + @($TelegramLogLegacyShortcutNames)) {
            Remove-Item -LiteralPath (Join-Path $startupFolder $shortcutName) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-TelegramLogTaskExists {
    param([string]$TaskName)

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $queryOutput = & schtasks.exe /Query /TN $TaskName /FO LIST 2>&1
    $exists = ($LASTEXITCODE -eq 0)
    if (-not $exists -and ([string]($queryOutput | Out-String)) -match 'Access is denied|0x80070005') {
        # SYSTEM tasks may deliberately deny details to a non-elevated user. An
        # access-denied response for the exact name still proves the task exists.
        $exists = $true
    }
    $ErrorActionPreference = $oldErrorActionPreference
    return $exists
}

function Get-TelegramLogProcesses {
    param([string]$ScriptDir)

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @("powershell.exe", "pwsh.exe") -and
            $_.CommandLine -and
            $_.CommandLine.IndexOf($ScriptDir, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            ($_.CommandLine -like "*start-tray.ps1*" -or
             $_.CommandLine -like "*send-telegram-boot-log.ps1*" -or
             $_.CommandLine -like "*watch-power.ps1*")
        }
    return @($processes)
}

function Stop-TelegramLogProcesses {
    param([string]$ScriptDir)

    foreach ($process in @(Get-TelegramLogProcesses -ScriptDir $ScriptDir)) {
        if ($process.ProcessId -ne $PID) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-TelegramLogRemainingArtifacts {
    param(
        [string]$ScriptDir,
        [switch]$IncludeData,
        [switch]$IncludeConfig
    )

    $remaining = @()
    foreach ($task in @($TelegramLogTaskNames) + @($TelegramLogLegacyTaskNames)) {
        if (Test-TelegramLogTaskExists -TaskName $task) {
            $remaining += "Scheduled Task: $task"
        }
    }

    foreach ($wrapper in @($TelegramLogWrapperPaths) + @($TelegramLogLegacyWrapperPaths)) {
        if (Test-Path -LiteralPath $wrapper) {
            $remaining += "Wrapper: $wrapper"
        }
    }
    foreach ($legacyRuntime in $TelegramLogLegacyRuntimeDirs) {
        if (Test-Path -LiteralPath $legacyRuntime) {
            $remaining += "Legacy runtime directory: $legacyRuntime"
        }
    }

    $startupFolder = [Environment]::GetFolderPath("Startup")
    if ($startupFolder) {
        foreach ($shortcutName in @($TelegramLogStartupShortcutName) + @($TelegramLogLegacyShortcutNames)) {
            $shortcutPath = Join-Path $startupFolder $shortcutName
            if (Test-Path -LiteralPath $shortcutPath) {
                $remaining += "Startup shortcut: $shortcutPath"
            }
        }
    }

    foreach ($process in @(Get-TelegramLogProcesses -ScriptDir $ScriptDir)) {
        $remaining += "Running process: PID $($process.ProcessId)"
    }

    if ($IncludeData) {
        $dataPaths = @(
            $TelegramLogRuntimeDir,
            (Get-TelegramLogDirectory -ScriptDir $ScriptDir),
            (Join-Path $ScriptDir "state.json"),
            (Join-Path $ScriptDir "state.json.tmp")
        )
        foreach ($path in $dataPaths) {
            if (Test-Path -LiteralPath $path) {
                $remaining += "Runtime data: $path"
            }
        }
        Get-ChildItem -LiteralPath $ScriptDir -File -Filter "boot-log*.txt" -ErrorAction SilentlyContinue |
            ForEach-Object { $remaining += "Legacy log: $($_.FullName)" }
        Get-ChildItem -LiteralPath $ScriptDir -File -Filter "telegram-send-*.py" -ErrorAction SilentlyContinue |
            ForEach-Object { $remaining += "Temporary sender: $($_.FullName)" }
    }

    if ($IncludeConfig) {
        foreach ($configPath in @($TelegramLogConfigPath, (Join-Path $ScriptDir "config.json"), (Join-Path $ScriptDir "config.ps1"))) {
            if (Test-Path -LiteralPath $configPath) {
                $remaining += "Configuration: $configPath"
            }
        }
    }
    foreach ($markerName in @($TelegramLogConfigMarkerName) + @($TelegramLogLegacyConfigMarkerNames)) {
        $configMarkerPath = Join-Path $ScriptDir $markerName
        if (Test-Path -LiteralPath $configMarkerPath) {
            $remaining += "Installer marker: $configMarkerPath"
        }
    }

    return @($remaining)
}

function Stop-TelegramLogTray {
    param([string]$ScriptDir)

    $processes = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -like "*start-tray.ps1*" -and
            ([string]::IsNullOrWhiteSpace($ScriptDir) -or $_.CommandLine.IndexOf($ScriptDir, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Set-TelegramLogTaskState {
    param(
        [ValidateSet("ENABLE", "DISABLE")]
        [string]$State
    )

    $failedTasks = @()
    foreach ($task in $TelegramLogTaskNames) {
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & schtasks.exe /Change /TN $task "/$State" 2>&1 | Out-Null
        $changeExitCode = $LASTEXITCODE
        if ($State -eq "DISABLE") {
            # Disabling prevents future starts; explicitly end the long-running
            # watcher (and any short sender currently active) as well.
            & schtasks.exe /End /TN $task 2>&1 | Out-Null
        }
        $ErrorActionPreference = $oldErrorActionPreference
        if ($changeExitCode -ne 0) { $failedTasks += $task }
    }

    if ($failedTasks.Count -gt 0) {
        throw "Could not change Scheduled Task state: $($failedTasks -join ', ')"
    }

    if ($State -eq "ENABLE") {
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & schtasks.exe /Run /TN $TelegramLogTaskNames[2] 2>&1 | Out-Null
        $runExitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldErrorActionPreference
        if ($runExitCode -ne 0) {
            throw "Tasks were enabled, but the power watcher could not be started."
        }
    }
}

function Get-TelegramLogInstalledTaskCount {
    $count = 0
    foreach ($task in $TelegramLogTaskNames) {
        if (Test-TelegramLogTaskExists -TaskName $task) {
            $count++
        }
    }
    return $count
}

function Show-TelegramLogStatus {
    foreach ($task in $TelegramLogTaskNames) {
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $result = & schtasks.exe /Query /TN $task /FO LIST 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldErrorActionPreference

        if ($exitCode -eq 0) {
            Write-Host "[OK] $task"
            $result | Select-String -Pattern "TaskName:|Next Run Time:|Status:|Task To Run:" | ForEach-Object {
                Write-Host "     $($_.Line.Trim())"
            }
        } elseif (([string]($result | Out-String)) -match 'Access is denied|0x80070005') {
            Write-Host "[OK] $task (installed; details require Administrator)"
        } else {
            Write-Host "[--] $task not installed"
        }
    }
}
