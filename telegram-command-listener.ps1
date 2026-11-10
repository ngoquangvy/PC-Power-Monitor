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
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$LockScreenTaskName = "TelegramPowerMonitor-LockScreen"
$WakeDisplayTaskName = "TelegramPowerMonitor-WakeDisplay"
$listenerMutex = New-Object System.Threading.Mutex($false, "Local\TelegramPowerMonitorCommandListener")
$hasListenerLock = $false
$script:keepAwakeRequest = $null
$script:rdpConnected = $null
$script:autoHoldDeadlineTicks = $null
$script:rdpStateUnknown = $false
$AutoDisconnectHoldSeconds = 7200
$script:tailscaleLoginAttempt = $null

function Get-KeepAwakeClock {
    return [pscustomobject]@{
        Now = [datetimeoffset]::Now
        Ticks = [Diagnostics.Stopwatch]::GetTimestamp()
        Frequency = [Diagnostics.Stopwatch]::Frequency
    }
}

function Test-ActiveRdpSession {
    if (-not ('TelegramPowerMonitor.RemoteSessions' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace TelegramPowerMonitor {
    public static class RemoteSessions {
        [StructLayout(LayoutKind.Sequential)]
        private struct SessionInfo {
            public int SessionId;
            public IntPtr StationName;
            public int State;
        }
        [DllImport("wtsapi32.dll", SetLastError = true)]
        private static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        private static extern bool WTSQuerySessionInformationW(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);

        public static bool IsRdpActive() {
            IntPtr sessions;
            int count;
            if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out sessions, out count))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                bool queryFailed = false;
                int size = Marshal.SizeOf(typeof(SessionInfo));
                for (int i = 0; i < count; i++) {
                    var session = (SessionInfo)Marshal.PtrToStructure(IntPtr.Add(sessions, i * size), typeof(SessionInfo));
                    if (session.State != 0) continue; // WTSActive
                    IntPtr buffer;
                    int bytes;
                    // WTSClientProtocolType = 16; protocol 2 means RDP.
                    if (!WTSQuerySessionInformationW(IntPtr.Zero, session.SessionId, 16, out buffer, out bytes)) {
                        queryFailed = true;
                        continue;
                    }
                    try {
                        if (bytes < 2) { queryFailed = true; continue; }
                        if (Marshal.ReadInt16(buffer) == 2) return true;
                    } finally { WTSFreeMemory(buffer); }
                }
                if (queryFailed) throw new InvalidOperationException("Could not query every active session.");
                return false;
            } finally { WTSFreeMemory(sessions); }
        }
    }
}
'@
    }
    return [TelegramPowerMonitor.RemoteSessions]::IsRdpActive()
}

function Set-KeepAwakeRequest {
    param([bool]$Enabled)

    if (-not $Enabled) {
        if ($null -ne $script:keepAwakeRequest) {
            $script:keepAwakeRequest.Dispose()
            $script:keepAwakeRequest = $null
        }
        return
    }
    if ($null -ne $script:keepAwakeRequest) { return }
    if (-not ('TelegramPowerMonitor.KeepAwake' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace TelegramPowerMonitor {
    public sealed class KeepAwake : IDisposable {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SetThreadExecutionState(uint flags);

        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private readonly Thread worker;
        private int error;
        private volatile bool active;
        public bool Active { get { return active; } }

        public KeepAwake() {
            worker = new Thread(Run);
            worker.IsBackground = true;
            worker.Start();
            ready.WaitOne();
            if (error != 0) {
                Dispose();
                throw new Win32Exception(error);
            }
        }

        private void Run() {
            try {
                do {
                    // A dedicated thread owns this request, including clearing
                    // it. PowerShell runspaces may otherwise switch threads.
                    if (SetThreadExecutionState(0x80000001u) == 0) {
                        error = Marshal.GetLastWin32Error();
                        if (error == 0) error = 31;
                        return;
                    }
                    active = true;
                    ready.Set();
                } while (!stop.WaitOne(30000));
            } finally {
                // AUTO owns its two-hour grace interval before releasing this
                // request; do not rely on Windows resetting an RDP idle timer.
                SetThreadExecutionState(0x80000000u);
                active = false;
                ready.Set();
            }
        }

        public void Dispose() {
            stop.Set();
            worker.Join();
            stop.Dispose();
            ready.Dispose();
        }
    }
}
'@
    }
    $script:keepAwakeRequest = New-Object TelegramPowerMonitor.KeepAwake
}

function Set-KeepAwakeMode {
    param($State, [ValidateSet('Auto', 'On', 'Off')][string]$Mode)

    $previous = [string]$State.KeepAwakeMode
    $State.KeepAwakeMode = $Mode
    try {
        Update-KeepAwakeRequest -State $State
        $State.KeepAwakeEnabled = ($Mode -eq 'On')
        Write-CommandState -State $State
    } catch {
        $State.KeepAwakeMode = $previous
        $State.KeepAwakeEnabled = ($previous -eq 'On')
        Update-KeepAwakeRequest -State $State
        throw
    }
}

function Update-KeepAwakeRequest {
    param($State)
    $clock = Get-KeepAwakeClock
    $connected = $script:rdpConnected
    try { $connected = Test-ActiveRdpSession } catch {
        $script:rdpStateUnknown = $true
        if ($State.KeepAwakeMode -eq 'Auto') {
            # Unknown is not disconnected. Protect the machine even at startup
            # or after a worker failure, then let the caller log/retry WTS.
            if ($null -ne $script:keepAwakeRequest -and -not $script:keepAwakeRequest.Active) {
                Set-KeepAwakeRequest -Enabled $false
            }
            Set-KeepAwakeRequest -Enabled $true
            throw
        }
    }
    $recoveredFromUnknown = $script:rdpStateUnknown
    if ($State.KeepAwakeMode -eq 'Auto') { $script:rdpStateUnknown = $false }
    if ($script:rdpConnected -ne $connected) {
        Write-CommandLog "RDP_CONNECTION_CHANGED Connected=$connected"
        $script:rdpConnected = $connected
    }
    $previousHoldUntil = $State.AutoHoldUntil
    if ($State.KeepAwakeMode -eq 'Auto' -and -not $connected) {
        if ($null -eq $script:autoHoldDeadlineTicks -or $recoveredFromUnknown) {
            # Use a monotonic clock so changing the Windows clock cannot shorten
            # the interval. On listener restart, disconnected AUTO starts a full
            # interval again, conservatively extending rather than shortening it.
            $script:autoHoldDeadlineTicks = $clock.Ticks + ([double]$AutoDisconnectHoldSeconds * $clock.Frequency)
            $State.AutoHoldUntil = $clock.Now.AddSeconds($AutoDisconnectHoldSeconds).ToString('o')
            Write-CommandLog "KEEP_AWAKE_GRACE_STARTED Seconds=$AutoDisconnectHoldSeconds HoldUntil=$($State.AutoHoldUntil)"
        }
        $enabled = ($clock.Ticks -lt $script:autoHoldDeadlineTicks)
        if (-not $enabled) { $State.AutoHoldUntil = $null }
    } else {
        $script:autoHoldDeadlineTicks = $null
        $State.AutoHoldUntil = $null
        $enabled = ($State.KeepAwakeMode -eq 'On' -or ($State.KeepAwakeMode -eq 'Auto' -and $connected))
    }
    if ($null -ne $script:keepAwakeRequest -and -not $script:keepAwakeRequest.Active) {
        Set-KeepAwakeRequest -Enabled $false
    }
    $wasActive = ($null -ne $script:keepAwakeRequest)
    Set-KeepAwakeRequest -Enabled $enabled
    if ($wasActive -ne $enabled) {
        Write-CommandLog "KEEP_AWAKE_CHANGED Mode=$($State.KeepAwakeMode) Active=$enabled RdpConnected=$connected"
    }
    if ($previousHoldUntil -ne $State.AutoHoldUntil) {
        Write-CommandState -State $State
    }
}

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
                if (-not ($state.PSObject.Properties.Name -contains "KeepAwakeEnabled")) {
                    $state | Add-Member -NotePropertyName KeepAwakeEnabled -NotePropertyValue $false
                }
                if ($state.KeepAwakeEnabled -isnot [bool]) { throw "Invalid keep-awake state." }
                if (-not ($state.PSObject.Properties.Name -contains "KeepAwakeMode")) {
                    $mode = if ($state.KeepAwakeEnabled) { 'On' } else { 'Auto' }
                    $state | Add-Member -NotePropertyName KeepAwakeMode -NotePropertyValue $mode
                }
                if ($state.KeepAwakeMode -notin @('Auto', 'On', 'Off')) { throw "Invalid keep-awake mode." }
                if (-not ($state.PSObject.Properties.Name -contains 'AutoHoldUntil')) {
                    $state | Add-Member -NotePropertyName AutoHoldUntil -NotePropertyValue $null
                }
                if (-not ($state.PSObject.Properties.Name -contains 'TailscaleNeedsLoginAlerted')) {
                    $state | Add-Member -NotePropertyName TailscaleNeedsLoginAlerted -NotePropertyValue $false
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
        KeepAwakeEnabled = $false
        KeepAwakeMode = 'Auto'
        AutoHoldUntil = $null
        TailscaleNeedsLoginAlerted = $false
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
        [string]$Text,
        [switch]$ProtectContent
    )

    $body = @{
        chat_id = $ChatId
        text = $Text
        disable_web_page_preview = $true
    }
    if ($ProtectContent) { $body.protect_content = $true }
    $response = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/sendMessage" -Body $body -TimeoutSec 15
    if ($response.ok -ne $true) { throw "Telegram sendMessage did not confirm the reply." }
}

function Invoke-TailscaleRecoveryCli {
    param(
        [ValidateSet('Status', 'StartLogin', 'ConnectForLogin')][string]$Operation,
        [ValidatePattern('\A\\\\\.\\pipe\\tpm-test-[a-f0-9]+\z')][string]$TestSocket
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $TailscaleCli
    $info.Arguments = switch ($Operation) {
        'Status' { 'status --json --peers=false' }
        'StartLogin' { 'debug localapi POST login-interactive' }
        'ConnectForLogin' { 'debug localapi PATCH prefs -' }
    }
    if ($TestSocket) { $info.Arguments = "--socket $TestSocket $($info.Arguments)" }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = ($Operation -eq 'ConnectForLogin')
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($Operation -eq 'ConnectForLogin') {
            $process.StandardInput.Write('{"WantRunning":true,"WantRunningSet":true}')
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit(4000)) {
            try { $process.Kill() } catch {}
            throw 'Tailscale CLI timed out.'
        }
        # Drain both streams; never return raw stderr to Telegram or logs.
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 1000)) { throw 'Tailscale CLI output timed out.' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result }
    } finally { $process.Dispose() }
}

function Get-ApprovedTailscaleLoginUrl {
    param([string]$Url)
    # Only accept the official, device-specific authorization path, without
    # redirects, embedded credentials, query strings, or alternate hosts.
    if ($Url -cmatch '\Ahttps://login\.tailscale\.com/a/[a-zA-Z0-9_-]{1,256}\z') { return $Url }
    return $null
}

function Get-TailscaleHealth {
    param([switch]$IncludeLoginUrl)
    $service = Get-Service -Name Tailscale -ErrorAction Stop
    $backendState = "Unknown"
    $online = $false
    $keyExpiry = $null
    $loginUrl = $null
    if (Test-Path -LiteralPath $TailscaleCli) {
        try {
            $result = Invoke-TailscaleRecoveryCli -Operation Status
            if ($result.ExitCode -ne 0) { throw 'Tailscale status command failed.' }
            $status = $result.Output | ConvertFrom-Json
            $backendState = [string]$status.BackendState
            if ($backendState -notmatch '\A[A-Za-z]{1,40}\z') { throw 'Invalid Tailscale backend state.' }
            $online = ($status.Self.Online -eq $true)
            $parsedExpiry = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse([string]$status.Self.KeyExpiry, [ref]$parsedExpiry) -and $parsedExpiry.Year -gt 1) {
                $keyExpiry = $parsedExpiry
            }
            if ($IncludeLoginUrl -and $backendState -eq 'NeedsLogin') {
                $loginUrl = Get-ApprovedTailscaleLoginUrl -Url $status.AuthURL
                if ($status.AuthURL -and -not $loginUrl) { $backendState = 'UntrustedLoginUrl' }
            }
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
        KeyExpiry = $keyExpiry
        LoginUrl = $loginUrl
    }
}

function Test-TailscaleLoginChat {
    param($Message, [string]$AllowedChatId)
    return ($AllowedChatId -match '\A[1-9][0-9]*\z' -and
        $Message.chat.type -eq 'private' -and
        [string]$Message.chat.id -eq $AllowedChatId -and
        [string]$Message.from.id -eq $AllowedChatId)
}

function Get-TailscaleLoginReply {
    $health = Get-TailscaleHealth -IncludeLoginUrl
    $canStart = ($null -eq $script:tailscaleLoginAttempt -or $script:tailscaleLoginAttempt.Elapsed.TotalSeconds -ge 60)
    if ($health.BackendState -eq 'NeedsLogin' -and $health.ServiceStatus -eq 'Running' -and -not $health.LoginUrl -and $canStart) {
        # Request interactive authentication without resetting prefs, forcing
        # re-auth on a healthy device, or switching the current profile.
        $result = Invoke-TailscaleRecoveryCli -Operation ConnectForLogin
        if ($result.ExitCode -ne 0) { throw 'Tailscale rejected the request to connect.' }
        $health = Get-TailscaleHealth -IncludeLoginUrl
        if ($health.BackendState -eq 'NeedsLogin' -and $health.ServiceStatus -eq 'Running' -and -not $health.LoginUrl) {
            $result = Invoke-TailscaleRecoveryCli -Operation StartLogin
            if ($result.ExitCode -ne 0) { throw 'Tailscale rejected the interactive login request.' }
        }
        $script:tailscaleLoginAttempt = [Diagnostics.Stopwatch]::StartNew()
        while ($script:tailscaleLoginAttempt.Elapsed.TotalSeconds -lt 20) {
            $health = Get-TailscaleHealth -IncludeLoginUrl
            if ($health.LoginUrl -or $health.BackendState -ne 'NeedsLogin') { break }
            Start-Sleep -Milliseconds 750
        }
    }

    $url = if ($health.BackendState -eq 'NeedsLogin' -and $health.ServiceStatus -eq 'Running') {
        Get-ApprovedTailscaleLoginUrl -Url $health.LoginUrl
    }
    $text = if ($url) {
        "Authorize $env:COMPUTERNAME with your usual Tailscale account. You can open this link on your phone, then check /health.`n$url"
    } elseif ($health.BackendState -eq 'NeedsLogin') {
        'Tailscale requires sign-in, but no link is available yet. Wait a few seconds and send /tailscale_login again to check for the link.'
    } elseif ($health.BackendState -eq 'NeedsMachineAuth') {
        'Tailscale is waiting for device approval. Approve this PC in your Tailscale admin console, then check /health.'
    } elseif ($health.BackendState -eq 'UntrustedLoginUrl') {
        'Tailscale returned a link outside the supported login address. No link was sent; check the local Tailscale client.'
    } else {
        "Tailscale: service=$($health.ServiceStatus); backend=$($health.BackendState); online=$($health.Online). No login was started."
    }
    return [pscustomobject]@{ Text = $text; HasLoginUrl = [bool]$url; BackendState = $health.BackendState }
}

function Update-TailscaleLoginAlert {
    param($State, [string]$Token, [string]$ChatId)
    if ($ChatId -notmatch '\A[1-9][0-9]*\z') { return }
    $health = Get-TailscaleHealth
    if ($health.ServiceStatus -ne 'Running') { return }
    if ($health.BackendState -eq 'NeedsLogin' -and -not $State.TailscaleNeedsLoginAlerted) {
        Send-CommandReply -Token $Token -ChatId $ChatId -Text "Tailscale on $env:COMPUTERNAME needs sign-in. Send /tailscale_login to get a recovery link."
        $State.TailscaleNeedsLoginAlerted = $true
        Write-CommandState -State $State
        Write-CommandLog 'TAILSCALE_LOGIN_REQUIRED AlertSent=True'
    } elseif ($health.BackendState -eq 'Running') {
        $script:tailscaleLoginAttempt = $null
        if ($State.TailscaleNeedsLoginAlerted) {
            $State.TailscaleNeedsLoginAlerted = $false
            Write-CommandState -State $State
            Write-CommandLog 'TAILSCALE_LOGIN_RESTORED'
        }
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
        if ($tailscale.KeyExpiry) { $tailscaleText += "; key expiry=$($tailscale.KeyExpiry.ToLocalTime().ToString('yyyy-MM-dd HH:mm zzz'))" }
        if ($tailscale.BackendState -eq 'NeedsLogin') { $tailscaleText += '; use /tailscale_login in private chat' }
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

    $keepAwakeText = if ($null -ne $script:keepAwakeRequest -and $script:keepAwakeRequest.Active) {
        "ON (automatic sleep blocked; /allow_sleep to turn off)"
    } elseif ($state.KeepAwakeMode -eq 'On') {
        "requested ON but not active in this process"
    } else {
        "OFF (Windows sleep policy applies)"
    }
    $graceSeconds = 0
    if ($state.KeepAwakeMode -eq 'Auto' -and $null -ne $script:autoHoldDeadlineTicks) {
        $clock = Get-KeepAwakeClock
        $graceSeconds = [math]::Max(0, [math]::Ceiling(($script:autoHoldDeadlineTicks - $clock.Ticks) / $clock.Frequency))
    }

    return @(
        "PC health",
        "Computer: $computer",
        "Time: $($now.ToString('yyyy-MM-dd HH:mm:ss zzz'))",
        "Uptime: $uptime",
        "Memory: $memory",
        "Tailscale: $tailscaleText",
        "Keep awake: $keepAwakeText",
        "Keep awake mode: $($state.KeepAwakeMode); RDP connected: $script:rdpConnected",
        "RDP status uncertain: $script:rdpStateUnknown; disconnect grace remaining: $graceSeconds seconds",
        "Tasks: $($taskSummary -join '; ')"
    ) -join "`n"
}

function Get-CommandHelpReply {
    return @(
        "Telegram Power Monitor commands",
        "/health - PC, Tailscale, and task health",
        "/keep_awake - keep PC awake until /allow_sleep",
        "/allow_sleep - stop keeping PC awake",
        "/auto_keep_awake - keep awake during RDP and for 2 hours after disconnect",
        "/restart_tailscale - restart only Tailscale",
        "/tailscale_login - request a recovery link when Tailscale needs sign-in (private chat)",
        "/restart_pc - request a Windows restart",
        "/confirm_restart - confirm within 2 minutes",
        "/cancel_restart - cancel a pending restart",
        "/lock_screen - lock the current Windows session",
        "/wake_display - wake display and reset idle timer",
        "/enable_autologon - enable AutoLogon flag for next boot",
        "/disable_autologon - disable AutoLogon flag"
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

    # Query failures are retried by the polling loop without losing the saved mode.
    try { Update-KeepAwakeRequest -State $state } catch { Write-CommandLog "KEEP_AWAKE_QUERY_ERROR Type=$($_.Exception.GetType().Name)" }
    Write-CommandLog "KEEP_AWAKE_RESTORED Mode=$($state.KeepAwakeMode)"

    # Commands sent before the listener is installed are deliberately ignored.
    # This prevents a stale /restart_tailscale message from being executed later.
    if ($null -eq $state.NextUpdateOffset) {
        $backlog = Get-TelegramUpdates -Token $token -Offset 0 -TimeoutSeconds 0
        foreach ($update in $backlog) { Advance-UpdateOffset -State $state -Update $update }
    }
    Write-CommandLog "COMMAND_LISTENER_STARTED Commands=/help,/health,/keep_awake,/allow_sleep,/auto_keep_awake,/restart_tailscale,/tailscale_login,/restart_pc,/confirm_restart,/cancel_restart,/lock_screen,/wake_display,/enable_autologon,/disable_autologon"

    $lastPollErrorAt = [datetimeoffset]::MinValue
    $lastPowerErrorAt = [datetimeoffset]::MinValue
    $nextTailscaleCheck = [datetimeoffset]::MinValue
    while ($true) {
        try {
            try { Update-KeepAwakeRequest -State $state } catch {
                if ([datetimeoffset]::Now -ge $lastPowerErrorAt.AddMinutes(5)) {
                    Write-CommandLog "KEEP_AWAKE_QUERY_ERROR Type=$($_.Exception.GetType().Name)"
                    $lastPowerErrorAt = [datetimeoffset]::Now
                }
            }
            if ([datetimeoffset]::UtcNow -ge $nextTailscaleCheck) {
                $nextTailscaleCheck = [datetimeoffset]::UtcNow.AddMinutes(1)
                try { Update-TailscaleLoginAlert -State $state -Token $token -ChatId $allowedChatId } catch {
                    Write-CommandLog "TAILSCALE_LOGIN_CHECK_ERROR Type=$($_.Exception.GetType().Name)"
                }
            }
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
                    } elseif ($text -match '(?i)^/(keep_awake|allow_sleep|auto_keep_awake)(?:@[A-Za-z0-9_]+)?\s*$') {
                        $mode = switch ($Matches[1].ToLowerInvariant()) { 'keep_awake' { 'On' }; 'allow_sleep' { 'Off' }; 'auto_keep_awake' { 'Auto' } }
                        try {
                            Set-KeepAwakeMode -State $state -Mode $mode
                            Write-CommandLog "COMMAND_KEEP_AWAKE UpdateId=$($update.update_id) Mode=$mode"
                            $reply = if ($mode -eq 'On') {
                                "Keep awake ON. Automatic sleep is blocked; the display can still turn off and lock. This setting is restored after restart. Send /allow_sleep to turn it off."
                            } elseif ($mode -eq 'Auto') {
                                "Keep awake AUTO. Hold while RDP is connected and for 2 hours after disconnect. Reconnecting cancels the countdown; the next disconnect starts a fresh 2 hours."
                            } else {
                                "Keep awake OFF (automatic RDP hold disabled). Windows sleep settings apply again. Send /auto_keep_awake to restore automatic mode."
                            }
                        } catch {
                            Write-CommandLog "COMMAND_KEEP_AWAKE_ERROR UpdateId=$($update.update_id) Type=$($_.Exception.GetType().Name)"
                            $reply = "Could not change keep-awake mode. Check /health and the local log."
                        }
                        Send-CommandReply -Token $token -ChatId $allowedChatId -Text $reply
                    } elseif ($text -match '(?i)^/lock_screen(?:@[A-Za-z0-9_]+)?\s*$') {
                        & schtasks.exe /Run /TN $LockScreenTaskName 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "Windows could not start the lock-screen task." }
                        Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Windows lock-screen request accepted."
                        Write-CommandLog "COMMAND_LOCK_SCREEN UpdateId=$($update.update_id)"
                    } elseif ($text -match '(?i)^/wake_display(?:@[A-Za-z0-9_]+)?\s*$') {
                        & schtasks.exe /Run /TN $WakeDisplayTaskName 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "Windows could not start the wake-display task." }
                        Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Wake-display request accepted. The local log records the final result."
                        Write-CommandLog "COMMAND_WAKE_DISPLAY UpdateId=$($update.update_id)"
                    } elseif ($text -match '(?i)^/enable_autologon(?:@[A-Za-z0-9_]+)?\s*$') {
                        try {
                            $setupScript = Join-Path $ScriptDir "setup-autologon.ps1"
                            $out = & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $setupScript -SetFlagOnly -Enable 2>&1 | Out-String
                            if ($LASTEXITCODE -ne 0) { throw $out.Trim() }
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "AutoLogon enabled for next boot.`n$($out.Trim())"
                            Write-CommandLog "COMMAND_ENABLE_AUTOLOGON UpdateId=$($update.update_id)"
                        } catch {
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Failed to enable AutoLogon: $($_.Exception.Message)"
                            Write-CommandLog "COMMAND_ENABLE_AUTOLOGON_ERROR UpdateId=$($update.update_id) Error=$($_.Exception.Message)"
                        }
                    } elseif ($text -match '(?i)^/disable_autologon(?:@[A-Za-z0-9_]+)?\s*$') {
                        try {
                            $setupScript = Join-Path $ScriptDir "setup-autologon.ps1"
                            $out = & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $setupScript -SetFlagOnly -Disable 2>&1 | Out-String
                            if ($LASTEXITCODE -ne 0) { throw $out.Trim() }
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "AutoLogon disabled.`n$($out.Trim())"
                            Write-CommandLog "COMMAND_DISABLE_AUTOLOGON UpdateId=$($update.update_id)"
                        } catch {
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text "Failed to disable AutoLogon: $($_.Exception.Message)"
                            Write-CommandLog "COMMAND_DISABLE_AUTOLOGON_ERROR UpdateId=$($update.update_id) Error=$($_.Exception.Message)"
                        }
                    } elseif ($text -match '(?i)^/tailscale_login(?:@[A-Za-z0-9_]+)?\s*$') {
                        if (-not (Test-TailscaleLoginChat -Message $message -AllowedChatId $allowedChatId)) {
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text 'Tailscale login links are available only in the configured private chat.'
                            Write-CommandLog "COMMAND_TAILSCALE_LOGIN_IGNORED UpdateId=$($update.update_id) Reason=PrivateChatRequired"
                        } else {
                            try {
                                $reply = Get-TailscaleLoginReply
                            } catch {
                                Write-CommandLog "COMMAND_TAILSCALE_LOGIN_ERROR UpdateId=$($update.update_id) Type=$($_.Exception.GetType().Name)"
                                $reply = [pscustomobject]@{ Text = 'Could not request Tailscale sign-in. Check /health and try again.'; HasLoginUrl = $false; BackendState = 'Error' }
                            }
                            Send-CommandReply -Token $token -ChatId $allowedChatId -Text $reply.Text -ProtectContent:$reply.HasLoginUrl
                            Write-CommandLog "COMMAND_TAILSCALE_LOGIN UpdateId=$($update.update_id) Backend=$($reply.BackendState) LinkSent=$($reply.HasLoginUrl)"
                        }
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
    Set-KeepAwakeRequest -Enabled $false
    if ($hasListenerLock) {
        try { $listenerMutex.ReleaseMutex() } catch {}
    }
    $listenerMutex.Dispose()
}
