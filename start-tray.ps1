$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

trap {
    try { Write-TelegramLog -ScriptDir $ScriptDir -Message "TRAY_ERROR $($_.Exception.Message)" -RetentionDays 5 } catch {}
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$trayMutex = New-Object System.Threading.Mutex($false, "Local\TelegramPowerMonitorTray")
$hasTrayLock = $trayMutex.WaitOne(0)
if (-not $hasTrayLock) {
    $trayMutex.Dispose()
    exit 0
}

$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$SendScript = Join-Path $ScriptDir "send-telegram-boot-log.ps1"
$StatusScript = Join-Path $ScriptDir "status.ps1"
$SettingsScript = Join-Path $ScriptDir "setup-config.ps1"
$AutoLogonScript = Join-Path $ScriptDir "setup-autologon.ps1"
$ManageTasksScript = Join-Path $ScriptDir "manage-tasks.ps1"
$InstallCmd = Join-Path $ScriptDir "INSTALL.cmd"
$UninstallCmd = Join-Path $ScriptDir "UNINSTALL.cmd"
$LogDirectory = Get-TelegramLogDirectory -ScriptDir $ScriptDir
$StatePath = Join-Path $ScriptDir "state.json"
$AutoLogonMarkerPath = Join-Path $TelegramLogRuntimeDir "autologon-managed.json"

function Start-HiddenPowerShell {
    param([string]$ArgumentLine)

    Start-Process -FilePath $PowerShell -ArgumentList $ArgumentLine -WindowStyle Hidden | Out-Null
}

function Start-VisiblePowerShell {
    param([string]$ArgumentLine)

    Start-Process -FilePath $PowerShell -ArgumentList $ArgumentLine | Out-Null
}

function Show-TrayMessage {
    param([string]$Text, [string]$Title = "Telegram Power Monitor", [switch]$ErrorMessage)

    $icon = if ($ErrorMessage) { [System.Windows.Forms.MessageBoxIcon]::Error } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

function Show-TrayBalloon {
    param([string]$Text)

    $notifyIcon.BalloonTipTitle = "Telegram Power Monitor"
    $notifyIcon.BalloonTipText = $Text
    $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $notifyIcon.ShowBalloonTip(4000)
}

function Invoke-ElevatedTaskState {
    param([ValidateSet("ENABLE", "DISABLE")][string]$State)

    if ((Get-TelegramLogInstalledTaskCount) -ne $TelegramLogTaskNames.Count) {
        Show-TrayMessage -Text "Scheduled Tasks are not fully installed. Run Install / repair tasks first." -ErrorMessage
        return
    }

    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ManageTasksScript`" -State $State"
    $process = Start-Process -FilePath $PowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Windows could not change the Scheduled Task state."
    }
    Update-TrayText
    $resultText = if ($State -eq "ENABLE") { "Scheduled Tasks enabled; power watcher started." } else { "Scheduled Tasks disabled; running watcher stopped." }
    Show-TrayBalloon -Text $resultText
}

function Invoke-ScheduledTaskToggle {
    if ((Get-TelegramLogInstalledTaskCount) -ne $TelegramLogTaskNames.Count) {
        Show-TrayMessage -Text "Scheduled Tasks are not fully installed. Run Install / repair tasks first." -ErrorMessage
        return
    }

    $enabled = Get-TelegramLogScheduledTaskEnabledState
    if ($null -eq $enabled) {
        throw "Scheduled Task state is unknown. Run Install / repair tasks once to synchronize it."
    }
    Invoke-ElevatedTaskState -State $(if ($enabled) { "DISABLE" } else { "ENABLE" })
}

function Get-AutoLogonTrayState {
    if (-not (Test-Path -LiteralPath $AutoLogonScript)) {
        return [pscustomobject]@{ Managed = $false; Enabled = $false; Text = "AutoLogon support unavailable" }
    }
    if (-not (Test-Path -LiteralPath $AutoLogonMarkerPath)) {
        return [pscustomobject]@{ Managed = $false; Enabled = $false; Text = "AutoLogon not configured" }
    }

    try {
        $property = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -ErrorAction Stop
        $value = [string]$property.AutoAdminLogon
        $enabled = ($value -eq "1")
        return [pscustomobject]@{
            Managed = $true
            Enabled = $enabled
            Text = if ($enabled) { "AutoLogon enabled for next boot" } else { "AutoLogon disabled" }
        }
    } catch {
        return [pscustomobject]@{ Managed = $true; Enabled = $false; Text = "AutoLogon status unavailable" }
    }
}

function Invoke-AutoLogonSetup {
    if (-not (Test-Path -LiteralPath $AutoLogonScript)) {
        throw "AutoLogon setup script is missing. Run Install / repair tasks again."
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$AutoLogonScript`""
    $process = Start-Process -FilePath $PowerShell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "AutoLogon setup did not complete."
    }
    $state = Get-AutoLogonTrayState
    if (-not $state.Managed) {
        throw "AutoLogon setup finished without a managed configuration."
    }
    Show-TrayBalloon -Text $state.Text
}

function Invoke-AutoLogonToggle {
    $state = Get-AutoLogonTrayState
    if (-not $state.Managed) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "AutoLogon has not been configured by Telegram Power Monitor. Configure it now?",
            "Telegram Power Monitor",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Invoke-AutoLogonSetup
        }
        return
    }

    $operation = if ($state.Enabled) { "Disable" } else { "Enable" }
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$AutoLogonScript`" -SetFlagOnly -$operation"
    $process = Start-Process -FilePath $PowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Windows could not $($operation.ToLowerInvariant()) AutoLogon."
    }

    $updated = Get-AutoLogonTrayState
    if ($updated.Enabled -eq $state.Enabled) {
        throw "Windows did not report the requested AutoLogon state."
    }
    Show-TrayBalloon -Text $updated.Text
}

function Get-InternetStatusText {
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            if ($state.internetOnline -eq $true) {
                return "Internet: online"
            }
            if ($state.internetOnline -eq $false) {
                return "Internet: offline"
            }
        } catch {
        }
    }
    return "Internet: unknown"
}

function Update-TrayText {
    $installed = Get-TelegramLogInstalledTaskCount
    $internet = Get-InternetStatusText
    $text = "Telegram Power Monitor | Tasks: $installed/$($TelegramLogTaskNames.Count) | $internet"
    if ($text.Length -gt 63) {
        $text = $text.Substring(0, 60) + "..."
    }
    $notifyIcon.Text = $text
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Visible = $true

$statusItem = $menu.Items.Add("Status")
$settingsItem = $menu.Items.Add("Telegram settings...")
$autoLogonSetupItem = $menu.Items.Add("Configure AutoLogon...")
$autoLogonToggleItem = $menu.Items.Add("AutoLogon")
$testItem = $menu.Items.Add("Send test message")
$scheduledTaskToggleItem = $menu.Items.Add("Scheduled tasks")
$installItem = $menu.Items.Add("Install / repair tasks")
$uninstallItem = $menu.Items.Add("Uninstall tasks")
$menu.Items.Add("-") | Out-Null
$openLogItem = $menu.Items.Add("Open log")
$openFolderItem = $menu.Items.Add("Open folder")
$menu.Items.Add("-") | Out-Null
$exitItem = $menu.Items.Add("Exit tray")

$statusItem.Add_Click({
    try { Start-VisiblePowerShell "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$StatusScript`"" }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$settingsItem.Add_Click({
    try { Start-HiddenPowerShell "-NoProfile -STA -ExecutionPolicy Bypass -File `"$SettingsScript`"" }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$autoLogonSetupItem.Add_Click({
    try { Invoke-AutoLogonSetup }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$autoLogonToggleItem.Add_Click({
    try { Invoke-AutoLogonToggle }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$testItem.Add_Click({
    try {
        $process = Start-Process -FilePath $PowerShell -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$SendScript`" -Reason tray-test" -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Telegram test message could not be sent. Check Status and the latest log." }
        Update-TrayText
        Show-TrayBalloon -Text "Telegram test message sent successfully."
    } catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$scheduledTaskToggleItem.Add_Click({
    try { Invoke-ScheduledTaskToggle }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$installItem.Add_Click({
    try { Start-Process -FilePath $InstallCmd | Out-Null }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$uninstallItem.Add_Click({
    try { Start-Process -FilePath $UninstallCmd | Out-Null }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$openLogItem.Add_Click({
    try {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        $latestLog = Get-ChildItem -LiteralPath $LogDirectory -File -Filter "*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestLog) {
            Start-Process notepad.exe -ArgumentList "`"$($latestLog.FullName)`"" | Out-Null
        } else {
            Start-Process explorer.exe -ArgumentList "`"$LogDirectory`"" | Out-Null
        }
    } catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$openFolderItem.Add_Click({
    try { Start-Process explorer.exe -ArgumentList "`"$ScriptDir`"" | Out-Null }
    catch { Show-TrayMessage -Text $_.Exception.Message -ErrorMessage }
})

$exitItem.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu
$menu.Add_Opening({
    $tasksReady = ((Get-TelegramLogInstalledTaskCount) -eq $TelegramLogTaskNames.Count)
    $scheduledTaskToggleItem.Enabled = $tasksReady
    $scheduledEnabled = Get-TelegramLogScheduledTaskEnabledState
    $scheduledTaskToggleItem.Text = if (-not $tasksReady) {
        "Scheduled tasks (install first)"
    } elseif ($null -eq $scheduledEnabled) {
        "Scheduled tasks (state unknown; repair first)"
    } elseif ($scheduledEnabled) {
        "Disable scheduled tasks"
    } else {
        "Enable scheduled tasks"
    }
    $autoLogon = Get-AutoLogonTrayState
    $autoLogonSetupItem.Text = if ($autoLogon.Managed) { "Reconfigure AutoLogon..." } else { "Configure AutoLogon..." }
    $autoLogonToggleItem.Text = if ($autoLogon.Managed) {
        if ($autoLogon.Enabled) { "Disable AutoLogon" } else { "Enable AutoLogon" }
    } else {
        "Enable AutoLogon (configure first)"
    }
})
$notifyIcon.Add_DoubleClick({
    Start-VisiblePowerShell "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$StatusScript`""
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-TrayText })
$timer.Start()

Update-TrayText
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    try { $notifyIcon.Visible = $false } catch {}
    try { $notifyIcon.Dispose() } catch {}
    if ($hasTrayLock) {
        try { $trayMutex.ReleaseMutex() } catch {}
    }
    $trayMutex.Dispose()
}
