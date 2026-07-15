param(
    [ValidateRange(5, 300)]
    [int]$PreSleepSeconds = 10,

    [ValidateRange(10, 300)]
    [int]$MaxProbeIntervalSeconds = 60,

    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5,

    [switch]$ProbeOnce,

    [switch]$ProbeSuspendAudit
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$SendScript = Join-Path $ScriptDir "send-telegram-boot-log.ps1"
$StatePath = Join-Path $ScriptDir "state.json"
$watcherMutex = New-Object System.Threading.Mutex($false, "Local\TelegramPowerMonitorWatcher")
$hasWatcherLock = $false
$suspendAuditRegistered = $false

function Write-WatcherLog {
    param([string]$Message)
    Write-TelegramLog -ScriptDir $ScriptDir -Message $Message -RetentionDays $LogRetentionDays
}

function Initialize-PowerApi {
    if ("TelegramPowerMonitor.NativePower" -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace TelegramPowerMonitor {
    public static class NativePower {
        [StructLayout(LayoutKind.Sequential)]
        public struct SYSTEM_POWER_INFORMATION {
            public uint MaxIdlenessAllowed;
            public uint Idleness;
            public uint TimeRemaining;
            public byte CoolingMode;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEM_POWER_STATUS {
            public byte ACLineStatus;
            public byte BatteryFlag;
            public byte BatteryLifePercent;
            public byte SystemStatusFlag;
            public uint BatteryLifeTime;
            public uint BatteryFullLifeTime;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate uint DEVICE_NOTIFY_CALLBACK_ROUTINE(IntPtr context, uint type, IntPtr setting);

        [StructLayout(LayoutKind.Sequential)]
        private struct DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
            public DEVICE_NOTIFY_CALLBACK_ROUTINE Callback;
            public IntPtr Context;
        }

        [DllImport("powrprof.dll", EntryPoint="CallNtPowerInformation")]
        private static extern uint CallSystemPowerInformation(
            int informationLevel, IntPtr input, uint inputLength,
            out SYSTEM_POWER_INFORMATION output, uint outputLength);

        [DllImport("powrprof.dll", EntryPoint="CallNtPowerInformation")]
        private static extern uint CallUInt64PowerInformation(
            int informationLevel, IntPtr input, uint inputLength,
            out ulong output, uint outputLength);

        [DllImport("powrprof.dll", EntryPoint="CallNtPowerInformation")]
        private static extern uint CallUInt32PowerInformation(
            int informationLevel, IntPtr input, uint inputLength,
            out uint output, uint outputLength);

        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO input);

        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

        [DllImport("powrprof.dll")]
        private static extern uint PowerGetActiveScheme(IntPtr rootPowerKey, out IntPtr activePolicyGuid);

        [DllImport("powrprof.dll")]
        private static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid,
            ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);

        [DllImport("powrprof.dll")]
        private static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid,
            ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("powrprof.dll")]
        private static extern uint PowerRegisterSuspendResumeNotification(uint flags,
            ref DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS recipient, out IntPtr registrationHandle);

        [DllImport("powrprof.dll")]
        private static extern uint PowerUnregisterSuspendResumeNotification(IntPtr registrationHandle);

        private static DEVICE_NOTIFY_CALLBACK_ROUTINE suspendCallback;
        private static DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS suspendSubscription;
        private static IntPtr suspendRegistration = IntPtr.Zero;
        private static long suspendSequence;
        private static int currentCycleSendSucceeded;
        private static int lastSuspendHadSuccessfulSend;
        private static long lastSuspendUtcFileTime;

        private static uint OnSuspendResumeNotification(IntPtr context, uint type, IntPtr setting) {
            // PBT_APMSUSPEND. Do no I/O here: Windows gives applications only a
            // very small suspend window. Snapshot the already-completed send.
            if (type == 4) {
                Interlocked.Exchange(ref lastSuspendHadSuccessfulSend,
                    Volatile.Read(ref currentCycleSendSucceeded));
                Interlocked.Exchange(ref lastSuspendUtcFileTime, DateTime.UtcNow.ToFileTimeUtc());
                Interlocked.Increment(ref suspendSequence);
            }
            return 0;
        }

        public static SYSTEM_POWER_INFORMATION GetSystemPowerInformation(out uint status) {
            SYSTEM_POWER_INFORMATION value;
            status = CallSystemPowerInformation(12, IntPtr.Zero, 0, out value,
                (uint)Marshal.SizeOf(typeof(SYSTEM_POWER_INFORMATION)));
            return value;
        }

        public static ulong GetLastSleepTime(out uint status) {
            ulong value;
            status = CallUInt64PowerInformation(15, IntPtr.Zero, 0, out value, 8);
            return value;
        }

        public static uint GetExecutionState(out uint status) {
            uint value;
            status = CallUInt32PowerInformation(16, IntPtr.Zero, 0, out value, 4);
            return value;
        }

        public static ulong GetInteractiveSessionIdleSeconds(out uint status) {
            LASTINPUTINFO input = new LASTINPUTINFO();
            input.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref input)) {
                status = (uint)Marshal.GetLastWin32Error();
                return 0;
            }
            status = 0;
            uint currentTick = unchecked((uint)GetTickCount64());
            return unchecked(currentTick - input.dwTime) / 1000;
        }

        public static uint GetSystemSleepTimeoutSeconds(out uint status, out bool onAcPower) {
            SYSTEM_POWER_STATUS powerStatus;
            if (!GetSystemPowerStatus(out powerStatus)) {
                status = (uint)Marshal.GetLastWin32Error();
                onAcPower = false;
                return 0;
            }
            onAcPower = powerStatus.ACLineStatus == 1;

            IntPtr schemePointer;
            status = PowerGetActiveScheme(IntPtr.Zero, out schemePointer);
            if (status != 0) return 0;
            try {
                Guid scheme = (Guid)Marshal.PtrToStructure(schemePointer, typeof(Guid));
                Guid sleepSubgroup = new Guid("238c9fa8-0aad-41ed-83f4-97be242c8f20");
                Guid sleepAfter = new Guid("29f6c1db-86da-48c5-9fdb-f2b67b1f44da");
                uint value;
                status = onAcPower
                    ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref sleepSubgroup, ref sleepAfter, out value)
                    : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref sleepSubgroup, ref sleepAfter, out value);
                return status == 0 ? value : 0;
            } finally {
                LocalFree(schemePointer);
            }
        }

        public static bool RegisterSuspendAudit(out uint status) {
            if (suspendRegistration != IntPtr.Zero) {
                status = 0;
                return true;
            }
            suspendCallback = OnSuspendResumeNotification;
            suspendSubscription = new DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
                Callback = suspendCallback,
                Context = IntPtr.Zero
            };
            status = PowerRegisterSuspendResumeNotification(2, ref suspendSubscription, out suspendRegistration);
            return status == 0 && suspendRegistration != IntPtr.Zero;
        }

        public static uint UnregisterSuspendAudit() {
            if (suspendRegistration == IntPtr.Zero) return 0;
            uint status = PowerUnregisterSuspendResumeNotification(suspendRegistration);
            suspendRegistration = IntPtr.Zero;
            return status;
        }

        public static void SetCurrentCycleSendSucceeded(bool succeeded) {
            Volatile.Write(ref currentCycleSendSucceeded, succeeded ? 1 : 0);
        }

        public static long GetSuspendSequence() {
            return Interlocked.Read(ref suspendSequence);
        }

        public static bool GetLastSuspendHadSuccessfulSend() {
            return Volatile.Read(ref lastSuspendHadSuccessfulSend) != 0;
        }

        public static long GetLastSuspendUtcFileTime() {
            return Interlocked.Read(ref lastSuspendUtcFileTime);
        }

        public static bool TestSuspendAuditSnapshot() {
            long before = GetSuspendSequence();
            SetCurrentCycleSendSucceeded(true);
            OnSuspendResumeNotification(IntPtr.Zero, 4, IntPtr.Zero);
            bool passed = GetSuspendSequence() == before + 1 && GetLastSuspendHadSuccessfulSend();
            SetCurrentCycleSendSucceeded(false);
            return passed;
        }
    }
}
'@
}

function Get-WindowsPowerCountdown {
    $status = [uint32]0
    $info = [TelegramPowerMonitor.NativePower]::GetSystemPowerInformation([ref]$status)
    $executionStatus = [uint32]0
    $executionState = [TelegramPowerMonitor.NativePower]::GetExecutionState([ref]$executionStatus)
    $idleStatus = [uint32]0
    $idleSeconds = [TelegramPowerMonitor.NativePower]::GetInteractiveSessionIdleSeconds([ref]$idleStatus)
    $sleepTimeoutStatus = [uint32]0
    $onAcPower = $false
    $sleepTimeoutSeconds = [TelegramPowerMonitor.NativePower]::GetSystemSleepTimeoutSeconds([ref]$sleepTimeoutStatus, [ref]$onAcPower)

    $nativeTimerActive = ($status -eq 0 -and $info.TimeRemaining -ne [uint32]::MaxValue -and $info.TimeRemaining -gt 0)
    $interactiveSession = ([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0)
    $fallbackTimerActive = (-not $nativeTimerActive -and $interactiveSession -and $idleStatus -eq 0 -and $sleepTimeoutStatus -eq 0 -and $sleepTimeoutSeconds -gt 0)
    $effectiveRemaining = if ($nativeTimerActive) {
        [uint64]$info.TimeRemaining
    } elseif ($fallbackTimerActive) {
        if ($idleSeconds -ge $sleepTimeoutSeconds) { [uint64]0 } else { [uint64]($sleepTimeoutSeconds - $idleSeconds) }
    } else {
        [uint64][uint32]::MaxValue
    }
    $timerSource = if ($nativeTimerActive) { "SystemPowerInformation" } elseif ($fallbackTimerActive) { "InteractiveSessionIdle" } else { "None" }

    return [pscustomobject]@{
        Status = $status
        MaxIdlenessAllowed = [uint32]$info.MaxIdlenessAllowed
        Idleness = [uint32]$info.Idleness
        TimeRemaining = $effectiveRemaining
        TimerActive = ($nativeTimerActive -or $fallbackTimerActive)
        TimerSource = $timerSource
        NativeTimeRemaining = [uint32]$info.TimeRemaining
        InteractiveSession = $interactiveSession
        IdleSeconds = [uint64]$idleSeconds
        IdleStatus = $idleStatus
        SleepTimeoutSeconds = [uint32]$sleepTimeoutSeconds
        SleepTimeoutStatus = $sleepTimeoutStatus
        OnAcPower = $onAcPower
        ExecutionState = [uint32]$executionState
        ExecutionStateStatus = $executionStatus
        SystemOrDisplayRequired = (($executionState -band 0x43) -ne 0)
    }
}

function Get-LastSleepCounter {
    $status = [uint32]0
    $value = [TelegramPowerMonitor.NativePower]::GetLastSleepTime([ref]$status)
    if ($status -ne 0) { return $null }
    return [uint64]$value
}

function Get-LastSleepTransitionSendTime {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$state.lastSleepTransitionNotificationAt)) { return $null }
        return [datetimeoffset]::Parse([string]$state.lastSleepTransitionNotificationAt)
    } catch {
        return $null
    }
}

function Invoke-PreSleepNotification {
    param([int]$SecondsRemaining, [string]$CycleId)

    $arguments = @(
        "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$SendScript`"",
        "-Reason", "pre-sleep",
        "-RemainingSeconds", "$SecondsRemaining",
        "-CycleId", $CycleId,
        "-LogRetentionDays", "$LogRetentionDays"
    )
    $process = Start-Process -FilePath $PowerShell -ArgumentList ($arguments -join " ") -WindowStyle Hidden -Wait -PassThru
    return $process.ExitCode
}

try {
    Initialize-PowerApi
    if (-not $ProbeOnce -and -not $ProbeSuspendAudit) {
        $hasWatcherLock = $watcherMutex.WaitOne(0)
        if (-not $hasWatcherLock) {
            Write-WatcherLog "WATCHER_SKIP Another watcher instance is already running"
            exit 0
        }
    }

    if ($ProbeSuspendAudit) {
        $auditStatus = [uint32]0
        $registered = [TelegramPowerMonitor.NativePower]::RegisterSuspendAudit([ref]$auditStatus)
        [pscustomobject]@{
            Registered = $registered
            Status = $auditStatus
            SnapshotTestPassed = [TelegramPowerMonitor.NativePower]::TestSuspendAuditSnapshot()
        } | Format-List
        if ($registered) { [void][TelegramPowerMonitor.NativePower]::UnregisterSuspendAudit() }
        exit $(if ($registered) { 0 } else { 1 })
    }

    if ($ProbeOnce) {
        Get-WindowsPowerCountdown | Format-List
        exit 0
    }

    $auditStatus = [uint32]0
    $suspendAuditRegistered = [TelegramPowerMonitor.NativePower]::RegisterSuspendAudit([ref]$auditStatus)
    if ($suspendAuditRegistered) {
        Write-WatcherLog "SUSPEND_AUDIT_REGISTERED Provider=PBT_APMSUSPEND"
    } else {
        Write-WatcherLog "SUSPEND_AUDIT_ERROR Status=$auditStatus"
    }

    Write-WatcherLog "WATCHER_STARTED PreSleepSeconds=$PreSleepSeconds MaxProbeIntervalSeconds=$MaxProbeIntervalSeconds"
    $armed = $true
    $cooldownUntil = [datetimeoffset]::MinValue
    $lastTimerSource = $null
    $lastSuspendSequence = [TelegramPowerMonitor.NativePower]::GetSuspendSequence()
    [TelegramPowerMonitor.NativePower]::SetCurrentCycleSendSucceeded($false)

    while ($true) {
        $suspendSequence = [TelegramPowerMonitor.NativePower]::GetSuspendSequence()
        if ($suspendSequence -ne $lastSuspendSequence) {
            $timerSendConfirmed = [TelegramPowerMonitor.NativePower]::GetLastSuspendHadSuccessfulSend()
            $suspendFileTime = [TelegramPowerMonitor.NativePower]::GetLastSuspendUtcFileTime()
            $suspendMoment = if ($suspendFileTime -gt 0) { [datetimeoffset][DateTime]::FromFileTimeUtc($suspendFileTime) } else { $null }
            $transitionSendConfirmed = $false
            $transitionSendTime = $null
            if ($suspendMoment) {
                # Event 566 normally precedes PBT_APMSUSPEND by about six seconds.
                # Give its sender a moment to finish before evaluating the receipt.
                for ($auditAttempt = 0; $auditAttempt -lt 3; $auditAttempt++) {
                    $transitionSendTime = Get-LastSleepTransitionSendTime
                    if ($transitionSendTime -and $transitionSendTime -ge $suspendMoment.AddSeconds(-30) -and $transitionSendTime -le $suspendMoment.AddSeconds(3)) {
                        $transitionSendConfirmed = $true
                        break
                    }
                    if ($auditAttempt -lt 2) { Start-Sleep -Seconds 1 }
                }
            }
            $confirmed = ($timerSendConfirmed -or $transitionSendConfirmed)
            $confirmationSource = if ($transitionSendConfirmed) { "KernelPower566" } elseif ($timerSendConfirmed) { "NativePowerTimer" } else { "None" }
            $suspendTimeText = if ($suspendMoment) { $suspendMoment.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz") } else { "Unknown" }
            Write-WatcherLog "SUSPEND_AUDIT Sequence=$suspendSequence PreSleepTelegramConfirmed=$confirmed Source=$confirmationSource SuspendSignalTime=$suspendTimeText"
            [TelegramPowerMonitor.NativePower]::SetCurrentCycleSendSucceeded($false)
            $lastSuspendSequence = $suspendSequence
        }

        $power = Get-WindowsPowerCountdown
        if ($power.TimerSource -ne $lastTimerSource) {
            Write-WatcherLog "POWER_TIMER_SOURCE Source=$($power.TimerSource) SleepTimeoutSeconds=$($power.SleepTimeoutSeconds) InteractiveSession=$($power.InteractiveSession)"
            $lastTimerSource = $power.TimerSource
        }
        if ($power.Status -ne 0 -and $power.TimerSource -ne "InteractiveSessionIdle") {
            Write-WatcherLog "POWER_API_ERROR Status=$($power.Status)"
            Start-Sleep -Seconds 30
            continue
        }

        if (-not $power.TimerActive -or $power.SystemOrDisplayRequired) {
            if ([datetimeoffset]::Now -ge $cooldownUntil) {
                if (-not $armed) { [TelegramPowerMonitor.NativePower]::SetCurrentCycleSendSucceeded($false) }
                $armed = $true
            }
            Start-Sleep -Seconds ([math]::Min(30, $MaxProbeIntervalSeconds))
            continue
        }

        $remaining = [int]$power.TimeRemaining
        if (-not $armed) {
            if ([datetimeoffset]::Now -ge $cooldownUntil -and $remaining -gt ($PreSleepSeconds + 30)) {
                $armed = $true
                [TelegramPowerMonitor.NativePower]::SetCurrentCycleSendSucceeded($false)
            } else {
                Start-Sleep -Seconds ([math]::Min(30, [math]::Max(1, $remaining)))
                continue
            }
        }

        if ($remaining -le $PreSleepSeconds) {
            $cycleId = [guid]::NewGuid().ToString("N")
            $sleepCounterBefore = Get-LastSleepCounter
            $nativeNotificationAttempted = ($power.TimerSource -eq "SystemPowerInformation")
            if ($nativeNotificationAttempted) {
                $exitCode = Invoke-PreSleepNotification -SecondsRemaining $remaining -CycleId $cycleId
                [TelegramPowerMonitor.NativePower]::SetCurrentCycleSendSucceeded($exitCode -eq 0)
                Write-WatcherLog "PRE_SLEEP_ATTEMPT Cycle=$cycleId Source=NativePowerTimer RemainingSeconds=$remaining SendExitCode=$exitCode"
            } else {
                # Interactive idle is only a prediction on Modern Standby. Wait
                # for Kernel-Power 566 before sending so canceled sleep is silent.
                [TelegramPowerMonitor.NativePower]::SetCurrentCycleSendSucceeded($false)
                Write-WatcherLog "PRE_SLEEP_PREDICTION Cycle=$cycleId Source=InteractiveSessionIdle RemainingSeconds=$remaining WaitingFor=KernelPower566"
            }
            $armed = $false
            $cooldownUntil = [datetimeoffset]::Now.AddSeconds(60)

            # If sleep occurs, this wait is suspended and resumes after wake. Otherwise the cycle is re-evaluated.
            Start-Sleep -Seconds ($PreSleepSeconds + 20)
            $sleepCounterAfter = Get-LastSleepCounter
            if ($sleepCounterBefore -ne $null -and $sleepCounterAfter -ne $null -and $sleepCounterAfter -ne $sleepCounterBefore) {
                if ($nativeNotificationAttempted) {
                    Write-WatcherLog "PRE_SLEEP_CONFIRMED Cycle=$cycleId Source=NativePowerTimer"
                } else {
                    Write-WatcherLog "SLEEP_PREDICTION_CONFIRMED Cycle=$cycleId Source=KernelPower566"
                }
            } else {
                if ($nativeNotificationAttempted) {
                    Write-WatcherLog "PRE_SLEEP_NOT_CONFIRMED Cycle=$cycleId Source=NativePowerTimer"
                } else {
                    Write-WatcherLog "SLEEP_PREDICTION_EXPIRED Cycle=$cycleId TelegramSent=False"
                }
            }
            continue
        }

        $waitSeconds = [math]::Min($MaxProbeIntervalSeconds, [math]::Max(1, $remaining - $PreSleepSeconds))
        Start-Sleep -Seconds $waitSeconds
    }
} catch {
    Write-WatcherLog "WATCHER_ERROR $($_.Exception.Message)"
    exit 1
} finally {
    if ($suspendAuditRegistered) {
        try { [void][TelegramPowerMonitor.NativePower]::UnregisterSuspendAudit() } catch {}
    }
    if ($hasWatcherLock) {
        try { $watcherMutex.ReleaseMutex() } catch {}
    }
    $watcherMutex.Dispose()
}
