param(
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

function Write-LockScreenLog {
    param([string]$Message)
    Write-TelegramLog -ScriptDir $ScriptDir -Message $Message -RetentionDays $LogRetentionDays
}

try {
    if (-not ("TelegramPowerMonitor.LockScreen" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TelegramPowerMonitor {
    public static class LockScreen {
        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool LockWorkStation();
    }
}
'@
    }

    if (-not [TelegramPowerMonitor.LockScreen]::LockWorkStation()) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    Write-LockScreenLog "LOCK_SCREEN_OK"
    exit 0
} catch {
    Write-LockScreenLog "LOCK_SCREEN_ERROR Type=$($_.Exception.GetType().Name)"
    exit 1
}
