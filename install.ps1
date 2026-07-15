param(
    [ValidateRange(5, 300)]
    [int]$PreSleepSeconds = 10,

    [ValidateRange(10, 300)]
    [int]$MaxProbeIntervalSeconds = 60,

    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5,

    [switch]$SendTest,
    [switch]$SkipTest,
    [switch]$NoTray,
    [switch]$NoElevation,
    [string]$SettingsUserSid,

    # Accepted for compatibility with test commands from the input-idle version; no longer used.
    [ValidateRange(0, 1440)] [int]$IdleMinutes = 0,
    [ValidateRange(1, 60)] [int]$CheckIntervalMinutes = 5,
    [ValidateRange(0, 60)] [int]$NotifyBeforeSleepMinutes = 5
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$StagingConfigPath = Join-Path $ScriptDir "config.json"
$LegacyConfigPath = Join-Path $ScriptDir "config.ps1"
$SetupScript = Join-Path $ScriptDir "setup-config.ps1"
$ManageTasksScript = Join-Path $ScriptDir "manage-tasks.ps1"
$SendScript = Join-Path $ScriptDir "send-telegram-boot-log.ps1"
$WatchScript = Join-Path $ScriptDir "watch-power.ps1"
$TrayScript = Join-Path $ScriptDir "start-tray.ps1"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

foreach ($requiredFile in @($SendScript, $WatchScript, $TrayScript, $SetupScript, $ManageTasksScript)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
        throw "Missing required file: $requiredFile"
    }
}

if ([string]::IsNullOrWhiteSpace($SettingsUserSid)) {
    $SettingsUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

$ConfigPath = Get-TelegramLogConfigCandidate -ScriptDir $ScriptDir
if (-not $ConfigPath -and (Test-Path -LiteralPath $LegacyConfigPath)) {
    Write-Host "Migrating the existing Telegram settings..."
    & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $SetupScript -MigrateLegacy -LegacyConfigPath $LegacyConfigPath -ConfigPath $StagingConfigPath
    if ($LASTEXITCODE -ne 0) { throw "Could not migrate the existing Telegram settings." }
    $ConfigPath = $StagingConfigPath
}
if (-not $ConfigPath) {
    Write-Host "Opening Telegram settings..."
    & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $SetupScript -ConfigPath $StagingConfigPath
    if ($LASTEXITCODE -ne 0) { throw "Installation cancelled because Telegram settings were not saved." }
    $ConfigPath = $StagingConfigPath
}
[void](Read-TelegramLogConfig -Path $ConfigPath)

if (-not (Test-TelegramLogAdmin)) {
    if ($NoElevation) {
        throw "Administrator rights are required to install system startup and power-event tasks."
    }

    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-PreSleepSeconds", "$PreSleepSeconds",
        "-MaxProbeIntervalSeconds", "$MaxProbeIntervalSeconds",
        "-LogRetentionDays", "$LogRetentionDays",
        "-SettingsUserSid", "$SettingsUserSid",
        "-NoElevation"
    )
    if ($SendTest) { $arguments += "-SendTest" }
    if ($NoTray) { $arguments += "-NoTray" }

    Write-Host "Requesting administrator permission..."
    $process = Start-Process -FilePath $PowerShell -ArgumentList ($arguments -join " ") -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

function Install-SecuredTelegramConfig {
    param([string]$SourcePath, [string]$UserSid)

    New-Item -ItemType Directory -Path $TelegramLogRuntimeDir -Force | Out-Null

    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($entry in @(
        @{ Sid = $UserSid; Rights = [Security.AccessControl.FileSystemRights]::Modify },
        @{ Sid = "S-1-5-18"; Rights = [Security.AccessControl.FileSystemRights]::FullControl },
        @{ Sid = "S-1-5-32-544"; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
    )) {
        $sid = New-Object Security.Principal.SecurityIdentifier($entry.Sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry.Rights, $inheritance, $propagation, "Allow")
        [void]$security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $TelegramLogRuntimeDir -AclObject $security

    if (-not ([IO.Path]::GetFullPath($SourcePath).Equals([IO.Path]::GetFullPath($TelegramLogConfigPath), [StringComparison]::OrdinalIgnoreCase))) {
        Copy-Item -LiteralPath $SourcePath -Destination $TelegramLogConfigPath -Force
    }
    $fileSecurity = New-Object Security.AccessControl.FileSecurity
    foreach ($entry in @(
        @{ Sid = $UserSid; Rights = [Security.AccessControl.FileSystemRights]::Modify },
        @{ Sid = "S-1-5-18"; Rights = [Security.AccessControl.FileSystemRights]::FullControl },
        @{ Sid = "S-1-5-32-544"; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
    )) {
        $sid = New-Object Security.Principal.SecurityIdentifier($entry.Sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry.Rights, "Allow")
        [void]$fileSecurity.AddAccessRule($rule)
    }
    $fileSecurity.SetAccessRuleProtection($true, $false)
    Set-Acl -LiteralPath $TelegramLogConfigPath -AclObject $fileSecurity
    [void](Read-TelegramLogConfig -Path $TelegramLogConfigPath)
}

function Register-PowerMonitorTask {
    param(
        [string]$Name,
        [string]$Description,
        [string]$ScriptPath,
        [string]$ScriptArguments,
        [ValidateSet("Boot", "Event", "BootAndEvent", "Logon", "LogonAndEvent")]
        [string]$TriggerType,
        [string]$EventSubscription,
        [int]$DelaySeconds = 0,
        [switch]$LongRunning,
        [string]$InteractiveUserSid
    )

    $service = New-Object -ComObject "Schedule.Service"
    $service.Connect()
    $rootFolder = $service.GetFolder("\")
    $definition = $service.NewTask(0)

    $definition.RegistrationInfo.Description = $Description
    $definition.Principal.UserId = if ($InteractiveUserSid) { $InteractiveUserSid } else { "SYSTEM" }
    $definition.Principal.LogonType = if ($InteractiveUserSid) { 3 } else { 5 } # INTERACTIVE_TOKEN / SERVICE_ACCOUNT
    $definition.Principal.RunLevel = 1  # TASK_RUNLEVEL_HIGHEST

    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = if ($LongRunning) { "PT0S" } else { "PT2M" }
    $definition.Settings.MultipleInstances = 2 # TASK_INSTANCES_IGNORE_NEW
    $definition.Settings.RestartCount = 10
    $definition.Settings.RestartInterval = "PT1M"

    if ($TriggerType -in @("Boot", "BootAndEvent")) {
        $bootTrigger = $definition.Triggers.Create(8) # TASK_TRIGGER_BOOT
        if ($DelaySeconds -gt 0) { $bootTrigger.Delay = "PT${DelaySeconds}S" }
        $bootTrigger.Enabled = $true
    }
    if ($TriggerType -in @("Event", "BootAndEvent")) {
        $eventTrigger = $definition.Triggers.Create(0) # TASK_TRIGGER_EVENT
        $eventTrigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">$EventSubscription</Select></Query></QueryList>"
        if ($DelaySeconds -gt 0) { $eventTrigger.Delay = "PT${DelaySeconds}S" }
        $eventTrigger.Enabled = $true
    }
    if ($TriggerType -in @("Logon", "LogonAndEvent")) {
        if (-not $InteractiveUserSid) { throw "A user SID is required for a logon-triggered task." }
        $logonTrigger = $definition.Triggers.Create(9) # TASK_TRIGGER_LOGON
        $logonTrigger.UserId = $InteractiveUserSid
        if ($DelaySeconds -gt 0) { $logonTrigger.Delay = "PT${DelaySeconds}S" }
        $logonTrigger.Enabled = $true
    }
    if ($TriggerType -eq "LogonAndEvent") {
        $eventTrigger = $definition.Triggers.Create(0) # TASK_TRIGGER_EVENT
        $eventTrigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">$EventSubscription</Select></Query></QueryList>"
        if ($DelaySeconds -gt 0) { $eventTrigger.Delay = "PT${DelaySeconds}S" }
        $eventTrigger.Enabled = $true
    }

    $action = $definition.Actions.Create(0) # TASK_ACTION_EXEC
    $action.Path = $PowerShell
    $action.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" $ScriptArguments"
    $action.WorkingDirectory = $ScriptDir

    $registerUser = if ($InteractiveUserSid) { $InteractiveUserSid } else { "SYSTEM" }
    $registerLogonType = if ($InteractiveUserSid) { 3 } else { 5 }
    $rootFolder.RegisterTaskDefinition($Name, $definition, 6, $registerUser, $null, $registerLogonType, $null) | Out-Null
}

function Start-MonitorTask {
    param([string]$TaskName)
    & schtasks.exe /Run /TN $TaskName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not start Scheduled Task: $TaskName" }
}

try {
    Install-SecuredTelegramConfig -SourcePath $ConfigPath -UserSid $SettingsUserSid
    Remove-Item -LiteralPath $StagingConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LegacyConfigPath -Force -ErrorAction SilentlyContinue
    foreach ($markerName in @($TelegramLogConfigMarkerName) + @($TelegramLogLegacyConfigMarkerNames)) {
        Remove-Item -LiteralPath (Join-Path $ScriptDir $markerName) -Force -ErrorAction SilentlyContinue
    }

    Stop-TelegramLogTray -ScriptDir $ScriptDir
    Stop-TelegramLogProcesses -ScriptDir $ScriptDir
    Remove-TelegramLogTasks

    $resumeEventQuery = "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]"

    Register-PowerMonitorTask `
        -Name $TelegramLogTaskNames[0] `
        -Description "Send one Telegram notification after Windows starts." `
        -ScriptPath $SendScript `
        -ScriptArguments "-Reason startup -LogRetentionDays $LogRetentionDays" `
        -TriggerType Boot `
        -DelaySeconds 30

    Register-PowerMonitorTask `
        -Name $TelegramLogTaskNames[1] `
        -Description "Send one Telegram notification after a real sleep or hibernate resume." `
        -ScriptPath $SendScript `
        -ScriptArguments "-Reason resume -LogRetentionDays $LogRetentionDays" `
        -TriggerType Event `
        -EventSubscription $resumeEventQuery `
        -DelaySeconds 30

    Register-PowerMonitorTask `
        -Name $TelegramLogTaskNames[2] `
        -Description "Monitor the Windows sleep countdown and interactive-session idle fallback." `
        -ScriptPath $WatchScript `
        -ScriptArguments "-PreSleepSeconds $PreSleepSeconds -MaxProbeIntervalSeconds $MaxProbeIntervalSeconds -LogRetentionDays $LogRetentionDays" `
        -TriggerType LogonAndEvent `
        -EventSubscription $resumeEventQuery `
        -DelaySeconds 45 `
        -LongRunning `
        -InteractiveUserSid $SettingsUserSid

    if ((Get-TelegramLogInstalledTaskCount) -ne $TelegramLogTaskNames.Count) {
        throw "Scheduled Task verification failed."
    }

    Remove-TelegramLogOldLogs -ScriptDir $ScriptDir -RetentionDays $LogRetentionDays

    if (-not $NoTray) {
        $startupFolder = [Environment]::GetFolderPath("Startup")
        if ($startupFolder) {
            $shortcutPath = Join-Path $startupFolder $TelegramLogStartupShortcutName
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $PowerShell
            $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TrayScript`""
            $shortcut.WorkingDirectory = $ScriptDir
            $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,277"
            $shortcut.Save()

            Start-Process -FilePath $PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TrayScript`"" -WindowStyle Hidden | Out-Null
        }
    }

    # Start monitoring now and announce that the monitor itself became active.
    Start-MonitorTask -TaskName $TelegramLogTaskNames[2]
    & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $SendScript -Reason monitor-start -LogRetentionDays $LogRetentionDays
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Monitor was installed, but the initial online notification could not be sent."
    }

    if ($SendTest) {
        & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $SendScript -Reason manual-test -LogRetentionDays $LogRetentionDays
        if ($LASTEXITCODE -ne 0) { throw "Manual test message failed." }
    }
} catch {
    Stop-TelegramLogTray -ScriptDir $ScriptDir
    Remove-TelegramLogTasks
    throw
}

Write-Host ""
Write-Host "Installation completed."
Write-Host "Startup notification: enabled (one per Windows boot)."
Write-Host "Resume notification: enabled and independent from all pre-sleep notifications."
Write-Host "Automatic pre-sleep notification: about $PreSleepSeconds seconds before the configured Windows sleep timeout expires."
Write-Host "Generic keyboard/mouse inactivity notifications: disabled; session idle is used only as a Windows sleep-timer fallback."
Write-Host "Manual shutdown notification: disabled."
Write-Host "Local log retention: $LogRetentionDays days."
Show-TelegramLogStatus
