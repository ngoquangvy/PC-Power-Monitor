$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")
$ConfigPath = Get-TelegramLogConfigCandidate -ScriptDir $ScriptDir
$telegramConfig = Read-TelegramLogConfig -Path $ConfigPath
$TelegramBotToken = $telegramConfig.TelegramBotToken

$uri = "https://api.telegram.org/bot$TelegramBotToken/getUpdates"
$updates = Invoke-RestMethod -Method Get -Uri $uri

$updates.result |
    Where-Object { $_.message.chat.id } |
    Select-Object -Last 10 @{Name="chat_id";Expression={$_.message.chat.id}}, @{Name="from";Expression={$_.message.from.username}}, @{Name="text";Expression={$_.message.text}}, @{Name="date";Expression={$_.message.date}} |
    Format-Table -AutoSize
