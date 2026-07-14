$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$SendScript = Join-Path $ScriptDir "send-telegram-boot-log.ps1"
$StatusScript = Join-Path $ScriptDir "status.ps1"
$InstallScript = Join-Path $ScriptDir "install.ps1"
$UninstallScript = Join-Path $ScriptDir "uninstall.ps1"
$SettingsScript = Join-Path $ScriptDir "setup-config.ps1"
$LogDirectory = Get-TelegramLogDirectory -ScriptDir $ScriptDir
$StatePath = Join-Path $ScriptDir "state.json"

function Start-HiddenPowerShell {
    param([string]$ArgumentLine)

    Start-Process -FilePath $PowerShell -ArgumentList $ArgumentLine -WindowStyle Hidden | Out-Null
}

function Start-VisiblePowerShell {
    param([string]$ArgumentLine)

    Start-Process -FilePath $PowerShell -ArgumentList $ArgumentLine | Out-Null
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
$testItem = $menu.Items.Add("Send test message")
$enableItem = $menu.Items.Add("Enable scheduled tasks")
$disableItem = $menu.Items.Add("Disable scheduled tasks")
$installItem = $menu.Items.Add("Install / repair tasks")
$uninstallItem = $menu.Items.Add("Uninstall tasks")
$menu.Items.Add("-") | Out-Null
$openLogItem = $menu.Items.Add("Open log")
$openFolderItem = $menu.Items.Add("Open folder")
$menu.Items.Add("-") | Out-Null
$exitItem = $menu.Items.Add("Exit tray")

$statusItem.Add_Click({
    Start-VisiblePowerShell "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$StatusScript`""
})

$settingsItem.Add_Click({
    Start-HiddenPowerShell "-NoProfile -STA -ExecutionPolicy Bypass -File `"$SettingsScript`""
})

$testItem.Add_Click({
    Start-HiddenPowerShell "-NoProfile -ExecutionPolicy Bypass -File `"$SendScript`" -Reason tray-test"
})

$enableItem.Add_Click({
    Set-TelegramLogTaskState -State ENABLE
    Update-TrayText
})

$disableItem.Add_Click({
    Set-TelegramLogTaskState -State DISABLE
    Update-TrayText
})

$installItem.Add_Click({
    Start-VisiblePowerShell "-NoProfile -ExecutionPolicy Bypass -File `"$InstallScript`""
})

$uninstallItem.Add_Click({
    Start-VisiblePowerShell "-NoProfile -ExecutionPolicy Bypass -File `"$UninstallScript`""
})

$openLogItem.Add_Click({
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $latestLog = Get-ChildItem -LiteralPath $LogDirectory -File -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) {
        Start-Process notepad.exe -ArgumentList "`"$($latestLog.FullName)`"" | Out-Null
    } else {
        Start-Process explorer.exe -ArgumentList "`"$LogDirectory`"" | Out-Null
    }
})

$openFolderItem.Add_Click({
    Start-Process explorer.exe -ArgumentList "`"$ScriptDir`"" | Out-Null
})

$exitItem.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Add_DoubleClick({
    Start-VisiblePowerShell "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$StatusScript`""
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-TrayText })
$timer.Start()

Update-TrayText
[System.Windows.Forms.Application]::Run()
