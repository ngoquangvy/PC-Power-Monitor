param(
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5,

    [switch]$ProbeOnce,

    [switch]$ProbeHealth
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$CommandStatePath = Join-Path $TelegramLogRuntimeDir "command-state.json"
$TailscaleCli = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
$listenerMutex = New-Object System.Threading.Mutex($false, "Local\TelegramPowerMonitorCommandListener")
$hasListenerLock = $false

function Write-CommandLog {
    param([string]$Message)
    Write-TelegramLog -ScriptDir $ScriptDir -Message $Message -RetentionDays $LogRetentionDays
}

function Read-CommandState {
    if (Test-Path -LiteralPath $CommandStatePath) {
        try {
            $state = Get-Content -LiteralPath $CommandStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state -and $state.PSObject.Properties.Name -contains "NextUpdateOffset") {
                if (-not ($state.PSObject.Properties.Name -contains "PendingRestartUntil")) {
                    $state | Add-Member -NotePropertyName PendingRestartUntil -NotePropertyValue $null
                }
                if (-not ($state.PSObject.Properties.Name -contains "PendingRestartStage")) {
                    $state | Add-Member -NotePropertyName PendingRestartStage -NotePropertyValue $null
                }
                return $state
            }
        } catch {
            Write-CommandLog "COMMAND_STATE_ERROR Could not read command state"
        }
    }
    return [pscustomobject]@{
        NextUpdateOffset = $null
        PendingRestartUntil = $null
        PendingRestartStage = $null
    }
}

function Write-CommandState {
    param($State)

    New-Item -ItemType Directory -Path $TelegramLogRuntimeDir -Force | Out-Null
    $temporaryPath = "$CommandStatePath.tmp"
    $State | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $CommandStatePath -Force
}

function Get-TelegramUpdates {
    param(
        [string]$Token,
        [Int64]$Offset = 0,
        [ValidateRange(0, 50)]
        [int]$TimeoutSeconds
    )

    $body = @{
        timeout = $TimeoutSeconds
        allowed_updates = '["message"]'
    }
    # Use a plain Int64 instead of Nullable<T>; PowerShell 5.1 can otherwise
    # serialize Nullable offsets incorrectly and replay the same update.
    if ($Offset -gt 0) { $body.offset = [string]$Offset }
    $response = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/getUpdates" -Body $body -TimeoutSec ($TimeoutSeconds + 15)
    if ($response.ok -ne $true) { throw "Telegram getUpdates did not confirm the request." }
    return @($response.result)
}

function Send-CommandReply {
    param(
        [string]$Token,
        [string]$ChatId,
        [string]$Text
    )

    $body = @{
        chat_id = $ChatId
        text = $Text
        disable_web_page_preview = $true
    }
    $response = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/sendMessage" -Body $body -TimeoutSec 15
    if ($response.ok -ne $true) { throw "Telegram sendMessage did not confirm the reply." }
}

function Get-TailscaleHealth {
    $service = Get-Service -Name Tailscale -ErrorAction Stop
    $backendState = "Unknown"
    $online = $false
    if (Test-Path -LiteralPath $TailscaleCli) {
        try {
            $status = & $TailscaleCli status --json 2>$null | ConvertFrom-Json
            $backendState = [string]$status.BackendState
            $online = ($status.Self.Online -eq $true)
        } catch {
            $backendState = "StatusQueryFailed"
        }
    } else {
        $backendState = "CliMissing"
    }
    return [pscustomobject]@{
        ServiceStatus = [string]$service.Status
        BackendState = $backendState
        Online = $online
    }
}

function Restart-TailscaleService {
    $before = Get-TailscaleHealth
    if ($before.ServiceStatus -eq "Running") {
        Restart-Service -Name Tailscale -Force -ErrorAction Stop
    } else {
        Start-Service -Name Tailscale -ErrorAction Stop
    }
    Start-Sleep -Seconds 8
    $after = Get-TailscaleHealth
    return [pscustomobject]@{ Before = $before; After = $after }
}

function Get-MachineHealthReply {
    $now = [datetimeoffset]::Now
    $computer = $env:COMPUTERNAME
    $uptime = "unknown"
    $memory = "unknown"
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $bootTime = [datetimeoffset]$os.LastBootUpTime
        $span = $now - $bootTime
        $uptime = "{0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
        $freeGiB = [math]::Round(([double]$os.FreePhysicalMemory * 1KB) / 1GB, 1)
        $totalGiB = [math]::Round(([double]$os.TotalVisibleMemorySize * 1KB) / 1GB, 1)
        $memory = "$freeGiB / $totalGiB GiB free"
    } catch {}

    try {
        $tailscale = Get-TailscaleHealth
        $tailscaleText = "service=$($tailscale.ServiceStatus); backend=$($tailscale.BackendState); online=$($tailscale.Online)"
    } catch {
        $tailscaleText = "health query failed"
    }

    $taskSummary = foreach ($taskName in $TelegramLogTaskNames) {
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            "$taskName=$($task.State)"
        } catch {
            "$taskName=Missing"
        }
    }

    return @(
        "PC health",
        "Computer: $computer",
        "Time: $($now.ToString('yyyy-MM-dd HH:mm:ss zzz'))",
        "Uptime: $uptime",
        "Memory: $memory",
        "Tailscale: $tailscaleText",
        "Tasks: $($taskSummary -join '; ')"
    ) -join "`n"
}

function Get-CommandHelpReply {
    return @(
        "Telegram Power Monitor commands",
        "/health - PC, Tailscale, and task health",
        "/restart_tailscale - restart only Tailscale",
        "/restart_pc - request a Windows restart",
        "/confirm_restart - confirm within 2 minutes",
        "/cancel_restart - cancel a pending restart"
    ) -join "`n"
}

function Advance-UpdateOffset {
    param($State, $Update)
    $State.NextUpdateOffset = [Int64]$Update.update_id + 1
    Write-CommandState -State $State
}

function Clear-PendingRestart {
    param($State)
    $State.PendingRestartUntil = $null
    $State.PendingRestartStage = $null
    Write-CommandState -State $State
}

function Get-PendingRestartDeadline {
    param($State)
    if ([string]::IsNullOrWhiteSpace([string]$State.PendingRestartUntil)) { return $null }
    try { return [datetimeoffset]$State.PendingRestartUntil } catch { return $null }
}

try {
    $hasListenerLock = $listenerMutex.WaitOne(0)
    if (-not $hasListenerLock) {
        Write-CommandLog "COMMAND_LISTENER_SKIP Another listener instance is already running"
        exit 0
    }

    $telegramConfig = Read-TelegramLogConfig -Path (Get-TelegramLogConfigCandidate -ScriptDir $ScriptDir)
    if ($telegramConfig.TelegramChatId -notmatch '^-?\d+$') {
        throw "Telegram recovery commands require a numeric Telegram Chat ID."
    }
    $token = $telegramConfig.TelegramBotToken
    $allowedChatId = $telegramConfig.TelegramChatId
    $state = Read-CommandState
    $existingRestartDeadline = Get-PendingRestartDeadline -State $state
    if ($state.PendingRestartStage -and ($null -eq $existingRestartDeadline -or $existingRestartDeadline -lt [datetimeoffset]::Now)) {
        Clear-PendingRestart -State $state
    }

    if ($ProbeOnce) {
        Get-TailscaleHealth | Format-List
        exit 0
    }
    if ($ProbeHealth) {
        Get-MachineHealthReply
        exit 0
    }

    # Commands sent before the listener is installed are deliberately ignored.
    # This prevents a stale /restart_tailscale message from being executed later.
    if ($null -eq $state.NextUpdateOffset) {
        $backlog = Get-TelegramUpdates -Token $token -Offset 0 -TimeoutSeconds 0
        foreach ($update in $backlog) { Advance-UpdateOffset -State $state -Update $update }
    }
    Write-CommandLog "COMMAND_LISTENER_STARTED Commands=/help,/health,/restart_tailscale,/restart_pc,/confirm_restart,/cancel_restart"

    $lastPollErrorAt = [datetimeoffset]::MinValue
    while ($true) {
        try {
            $updates = Get-TelegramUpdates -Token $token -Offset $state.NextUpdateOffset -TimeoutSeconds 25
            foreach ($update in $updates) {
                # Persist the acknowledgement before a command can cause a
                # side effect. This makes each Telegram update at-most-once.
                Advance-UpdateOffset -State $state -Update $update
                try {
                    $message = $update.message
                    $chatId = if ($message -and $message.chat) { [string]$message.chat.id } else { $null }
                    $text = if ($message) { [string]$message.text } else { $null }

                    if ($chatId -ne $allowedChatId) {
                        Write-CommandLog "COMMAND_IGNORED UpdateId=$($update.update_id) Reason=UnauthorizedChat"
                    } elseif ($text -match '(?i)^/help(?:@[A-Za-z0-9_]+)?\s*$') {
                        Send-CommandReply -Token $token -ChatId $allowedChatId -Text (Get-CommandHelpReply)
                        Write-CommandLog "COMMAND_HELP UpdateId=$($update.update_id)"
                    } elseif ($text -match '(?i)^/health(?:@[A-Za-z0-9_]+)?\s*$') {
                        Send-CommandReply -Token $token -ChatId $allowedChatId -Text (Get-MachineHealthReply)
                        Write-CommandLog "COMMAND_HEALTH UpdateId=$($update.update_id)"
                    } elseif ($text -match '(?i)^/restart_tailscale(?:@[A-Za-z0-9_]+)?\s*$') {
                        try {
                            $result = Restart-TailscaleService
                            $healthy = ($result.After.ServiceStatus -eq "Running" -and $result.After.BackendState -eq "Running" -and $result.After.Online)
                            $reply = if ($healthy) {
                                "Tailscale restarted successfully. Service: $($result.After.ServiceStatus); backend: $($result.After.BackendState); online: $($result.After.Online)."
                            } else {
                                "Tailscale restart completed, but health is not ready yet. Service: $($result.After.ServiceStatus); backend: $($result.After.BackendState); online: $($result.After.Online)."
                            }
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text $reply
                            Write-CommandLog "COMMAND_RESTART_TAILSCALE UpdateId=$($update.update_id) BeforeService=$($result.Before.ServiceStatus) AfterService=$($result.After.ServiceStatus) AfterBackend=$($result.After.BackendState) AfterOnline=$($result.After.Online)"
                        } catch {
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Tailscale restart failed. Check the local Telegram Power Monitor log."
                            Write-CommandLog "COMMAND_RESTART_TAILSCALE_ERROR UpdateId=$($update.update_id) Type=$($_.Exception.GetType().Name)"
                        }
                    } elseif ($text -match '(?i)^/restart_pc(?:@[A-Za-z0-9_]+)?\s*$') {
                        $pendingDeadline = Get-PendingRestartDeadline -State $state
                        if ($state.PendingRestartStage -and $pendingDeadline -and $pendingDeadline -ge [datetimeoffset]::Now) {
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "A restart request is already pending. Use /confirm_restart or /cancel_restart."
                        } else {
                            $confirmationDeadline = [datetimeoffset]::Now.AddMinutes(2)
                            $state.PendingRestartUntil = $confirmationDeadline.ToString("o")
                            $state.PendingRestartStage = "AwaitingConfirmation"
                            Write-CommandState -State $state
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Restart requested. Send /confirm_restart within 2 minutes to restart Windows, or /cancel_restart to cancel."
                            Write-CommandLog "COMMAND_RESTART_PC_REQUESTED UpdateId=$($update.update_id) ConfirmationUntil=$($state.PendingRestartUntil)"
                        }
                    } elseif ($text -match '(?i)^/confirm_restart(?:@[A-Za-z0-9_]+)?\s*$') {
                        $pendingDeadline = Get-PendingRestartDeadline -State $state
                        if ($state.PendingRestartStage -ne "AwaitingConfirmation" -or $null -eq $pendingDeadline -or $pendingDeadline -lt [datetimeoffset]::Now) {
                            Clear-PendingRestart -State $state
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "There is no valid restart request to confirm."
                        } else {
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Windows will restart in 45 seconds. Send /cancel_restart before then to cancel."
                            & (Join-Path $env:SystemRoot "System32\shutdown.exe") /r /t 45 /d p:4:1 /c "Telegram Power Monitor remote restart"
                            if ($LASTEXITCODE -ne 0) { throw "Windows restart request was rejected." }
                            $state.PendingRestartUntil = [datetimeoffset]::Now.AddSeconds(45).ToString("o")
                            $state.PendingRestartStage = "Scheduled"
                            Write-CommandState -State $state
                            Write-CommandLog "COMMAND_RESTART_PC_SCHEDULED UpdateId=$($update.update_id) DelaySeconds=45"
                        }
                    } elseif ($text -match '(?i)^/cancel_restart(?:@[A-Za-z0-9_]+)?\s*$') {
                        if ($state.PendingRestartStage -eq "Scheduled") {
                            & (Join-Path $env:SystemRoot "System32\shutdown.exe") /a
                            if ($LASTEXITCODE -ne 0) { throw "Windows could not cancel the scheduled restart." }
                            Clear-PendingRestart -State $state
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Scheduled Windows restart cancelled."
                            Write-CommandLog "COMMAND_RESTART_PC_CANCELLED UpdateId=$($update.update_id)"
                        } elseif ($state.PendingRestartStage -eq "AwaitingConfirmation") {
                            Clear-PendingRestart -State $state
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Restart request cancelled."
                            Write-CommandLog "COMMAND_RESTART_PC_CANCELLED UpdateId=$($update.update_id)"
                        } else {
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "There is no scheduled restart to cancel."
                        }
                    } else {
                        Write-CommandLog "COMMAND_IGNORED UpdateId=$($update.update_id) Reason=UnsupportedCommand"
                    }
                } catch {
                    # The update was already acknowledged above. Do not retry a
                    # failed side effect or response and risk a duplicate command.
                    Write-CommandLog "COMMAND_PROCESS_ERROR UpdateId=$($update.update_id) Type=$($_.Exception.GetType().Name)"
                }
            }
        } catch {
            if ([datetimeoffset]::Now -ge $lastPollErrorAt.AddMinutes(5)) {
                Write-CommandLog "COMMAND_POLL_ERROR Type=$($_.Exception.GetType().Name)"
                $lastPollErrorAt = [datetimeoffset]::Now
            }
            Start-Sleep -Seconds 10
        }
    }
} catch {
    Write-CommandLog "COMMAND_LISTENER_ERROR Type=$($_.Exception.GetType().Name)"
    exit 1
} finally {
    if ($hasListenerLock) {
        try { $listenerMutex.ReleaseMutex() } catch {}
    }
    $listenerMutex.Dispose()
}
