param(
    [ValidateSet("monitor-start", "startup", "resume", "pre-sleep", "manual-test", "tray-test")]
    [string]$Reason = "manual-test",

    [ValidateRange(0, 300)]
    [int]$RemainingSeconds = 0,

    [string]$CycleId,

    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$ConfigPath = Get-TelegramLogConfigCandidate -ScriptDir $ScriptDir
$StatePath = Join-Path $ScriptDir "state.json"
$stateMutex = New-Object System.Threading.Mutex($false, "Local\TelegramPowerMonitorState")
$hasStateLock = $false

function Write-LocalLog {
    param([string]$Message)
    Write-TelegramLog -ScriptDir $ScriptDir -Message $Message -RetentionDays $LogRetentionDays
}

function Add-StateProperty {
    param($State, [string]$Name, $DefaultValue)
    if (-not ($State.PSObject.Properties.Name -contains $Name)) {
        $State | Add-Member -NotePropertyName $Name -NotePropertyValue $DefaultValue
    }
}

function Read-State {
    $state = $null
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        } catch {
            Write-LocalLog "STATE_ERROR Could not read state.json"
        }
    }
    if (-not $state) { $state = [pscustomobject]@{} }

    Add-StateProperty $state "internetOnline" $null
    Add-StateProperty $state "lastInternetCheck" $null
    Add-StateProperty $state "lastSuccessfulSend" $null
    Add-StateProperty $state "lastNotifiedBootId" $null
    Add-StateProperty $state "lastStartupNotificationAt" $null
    Add-StateProperty $state "lastMonitorStartNotificationAt" $null
    Add-StateProperty $state "lastNotifiedResumeEventId" $null
    Add-StateProperty $state "lastResumeNotificationAt" $null
    Add-StateProperty $state "lastPreSleepCycleId" $null
    Add-StateProperty $state "lastPreSleepNotificationAt" $null
    Add-StateProperty $state "lastCheckAt" $null

    # Retired fields are retained for backward-compatible state loading but cannot suppress new event types.
    Add-StateProperty $state "idleNotificationSent" $false
    $state.idleNotificationSent = $false
    return $state
}

function Write-State {
    param($State)

    $tempPath = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
}

function Get-SystemSnapshot {
    $lastBoot = $null
    $uptime = "unknown"
    try {
        $lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $span = (Get-Date) - $lastBoot
        $uptime = "{0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
    } catch {
        Write-LocalLog "UPTIME_ERROR Could not read operating system uptime"
    }

    return [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        User = "$env:USERDOMAIN\$env:USERNAME"
        Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
        LastBoot = $lastBoot
        Uptime = $uptime
    }
}

function Get-ResumeEvent {
    $event = Get-WinEvent -FilterHashtable @{
        LogName = "System"
        ProviderName = "Microsoft-Windows-Power-Troubleshooter"
        Id = 1
    } -MaxEvents 1 -ErrorAction Stop

    [xml]$xml = $event.ToXml()
    $values = @{}
    foreach ($node in @($xml.Event.EventData.Data)) {
        $values[[string]$node.Name] = [string]$node.'#text'
    }

    $sleepTime = $null
    $wakeTime = $null
    if ($values.SleepTime) { $sleepTime = [datetimeoffset]::Parse($values.SleepTime) }
    if ($values.WakeTime) { $wakeTime = [datetimeoffset]::Parse($values.WakeTime) }

    return [pscustomobject]@{
        RecordId = [string]$event.RecordId
        EventTime = [datetimeoffset]$event.TimeCreated
        SleepTime = $sleepTime
        WakeTime = $wakeTime
        WakeSource = if ($values.WakeSourceText) { $values.WakeSourceText } else { "Unknown" }
        IsHibernateTransition = ($values.WakeSourceText -match "S4.*Hibernate")
    }
}

function Get-BootIdentity {
    try {
        $event = Get-WinEvent -FilterHashtable @{
            LogName = "System"
            ProviderName = "Microsoft-Windows-Kernel-Boot"
            Id = 27
        } -MaxEvents 1 -ErrorAction Stop
        return [pscustomobject]@{
            Id = "KernelBoot:$($event.RecordId)"
            Time = [datetimeoffset]$event.TimeCreated
            IsHibernateResume = ($event.Message -match "0x2")
        }
    } catch {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [pscustomobject]@{
            Id = "LastBoot:$($os.LastBootUpTime.ToUniversalTime().ToString('o'))"
            Time = [datetimeoffset]$os.LastBootUpTime
            IsHibernateResume = $false
        }
    }
}

function Send-TelegramNotification {
    param($State, [string[]]$MessageLines, [string]$EventName)

    $State.lastInternetCheck = (Get-Date).ToString("o")
    $uri = "https://api.telegram.org/bot$TelegramBotToken/sendMessage"
    $body = @{
        chat_id = $TelegramChatId
        text = ($MessageLines -join "`n")
        disable_web_page_preview = $true
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Method Post -Uri $uri -Body $body -TimeoutSec 8 | Out-Null
        $State.internetOnline = $true
        $State.lastSuccessfulSend = (Get-Date).ToString("o")
        Write-LocalLog "SEND_OK Event=$EventName"
    } catch {
        $State.internetOnline = $false
        Write-State $State
        Write-LocalLog "SEND_ERROR Event=$EventName Type=$($_.Exception.GetType().Name)"
        throw "Telegram notification could not be sent."
    }
}

try {
    Remove-TelegramLogOldLogs -ScriptDir $ScriptDir -RetentionDays $LogRetentionDays
    $hasStateLock = $stateMutex.WaitOne(15000)
    if (-not $hasStateLock) {
        Write-LocalLog "SKIP Another notification instance is running"
        exit 1
    }

    $telegramConfig = Read-TelegramLogConfig -Path $ConfigPath
    $TelegramBotToken = $telegramConfig.TelegramBotToken
    $TelegramChatId = $telegramConfig.TelegramChatId

    $state = Read-State
    $state.lastCheckAt = (Get-Date).ToString("o")
    $snapshot = Get-SystemSnapshot

    if ($Reason -eq "monitor-start") {
        $message = @(
            "Telegram power monitor started",
            "Computer: $($snapshot.Computer)",
            "Time: $($snapshot.Time)",
            "Status: startup, resume, and Windows power countdown monitoring are active"
        )
        Send-TelegramNotification -State $state -MessageLines $message -EventName "monitor-start"
        $state.lastMonitorStartNotificationAt = (Get-Date).ToString("o")
        Write-State $state
        exit 0
    }

    if ($Reason -eq "startup") {
        $boot = Get-BootIdentity
        if ($boot.IsHibernateResume) {
            Write-LocalLog "STARTUP_SKIP Kernel boot event represents hibernate resume; resume task owns this event"
            Write-State $state
            exit 0
        }
        if ($state.lastNotifiedBootId -eq $boot.Id) {
            Write-State $state
            exit 0
        }

        $message = @(
            "PC is online after startup",
            "Computer: $($snapshot.Computer)",
            "Boot event time: $($boot.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))",
            "Notification time: $($snapshot.Time)",
            "Status: Windows and Telegram monitor are running"
        )
        Send-TelegramNotification -State $state -MessageLines $message -EventName "startup"
        $state.lastNotifiedBootId = $boot.Id
        $state.lastStartupNotificationAt = (Get-Date).ToString("o")
        Write-State $state
        exit 0
    }

    if ($Reason -eq "resume") {
        $resume = Get-ResumeEvent
        if ($resume.IsHibernateTransition) {
            Write-LocalLog "RESUME_SKIP Intermediate S4-to-hibernate transition RecordId=$($resume.RecordId)"
            Write-State $state
            exit 0
        }
        if ($state.lastNotifiedResumeEventId -eq $resume.RecordId) {
            Write-State $state
            exit 0
        }

        $durationMinutes = "unknown"
        if ($resume.SleepTime -and $resume.WakeTime) {
            $durationMinutes = [math]::Max(0, [math]::Round(($resume.WakeTime - $resume.SleepTime).TotalMinutes, 1))
        }
        $message = @(
            "PC resumed from sleep/hibernate",
            "Computer: $($snapshot.Computer)",
            "Sleep time: $(if ($resume.SleepTime) { $resume.SleepTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') } else { 'unknown' })",
            "Wake time: $(if ($resume.WakeTime) { $resume.WakeTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') } else { $snapshot.Time })",
            "Sleep duration: $durationMinutes minutes",
            "Wake source: $($resume.WakeSource)"
        )
        Send-TelegramNotification -State $state -MessageLines $message -EventName "resume-$($resume.RecordId)"
        $state.lastNotifiedResumeEventId = $resume.RecordId
        $state.lastResumeNotificationAt = (Get-Date).ToString("o")
        Write-State $state
        exit 0
    }

    if ($Reason -eq "pre-sleep") {
        if ([string]::IsNullOrWhiteSpace($CycleId)) { $CycleId = [guid]::NewGuid().ToString("N") }
        if ($state.lastPreSleepCycleId -eq $CycleId) {
            Write-State $state
            exit 0
        }

        $message = @(
            "PC is approaching automatic sleep",
            "Computer: $($snapshot.Computer)",
            "Windows power timer remaining: about $RemainingSeconds seconds",
            "Time: $($snapshot.Time)",
            "Status: no active system blocker was reported by the Windows sleep countdown"
        )
        Send-TelegramNotification -State $state -MessageLines $message -EventName "pre-sleep-$CycleId"
        $state.lastPreSleepCycleId = $CycleId
        $state.lastPreSleepNotificationAt = (Get-Date).ToString("o")
        Write-State $state
        exit 0
    }

    $message = @(
        "Telegram power monitor test",
        "Computer: $($snapshot.Computer)",
        "User: $($snapshot.User)",
        "Time: $($snapshot.Time)",
        "Startup, resume, and Windows power countdown monitoring are enabled"
    )
    Send-TelegramNotification -State $state -MessageLines $message -EventName $Reason
    Write-State $state
    exit 0
} catch {
    Write-LocalLog "ERROR Reason=$Reason $($_.Exception.Message)"
    exit 1
} finally {
    if ($hasStateLock) {
        try { $stateMutex.ReleaseMutex() } catch {}
    }
    $stateMutex.Dispose()
}
