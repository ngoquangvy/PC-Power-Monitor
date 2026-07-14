param(
    [Parameter(Mandatory)]
    [ValidateSet("ENABLE", "DISABLE")]
    [string]$State
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

if (-not (Test-TelegramLogAdmin)) {
    throw "Administrator rights are required to change system Scheduled Tasks."
}

if ((Get-TelegramLogInstalledTaskCount) -ne $TelegramLogTaskNames.Count) {
    throw "Telegram Power Monitor tasks are not fully installed. Run INSTALL.cmd first."
}

Set-TelegramLogTaskState -State $State
