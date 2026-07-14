param(
    [ValidateRange(5, 300)]
    [int]$PreSleepSeconds = 10,

    [ValidateRange(10, 300)]
    [int]$MaxProbeIntervalSeconds = 60,

    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5,

    [switch]$ProbeOnce
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$SendScript = Join-Path $ScriptDir "send-telegram-boot-log.ps1"
$watcherMutex = New-Object System.Threading.Mutex($false, "Local\TelegramPowerMonitorWatcher")
$hasWatcherLock = $false

function Write-WatcherLog {
    param([string]$Message)
    Write-TelegramLog -ScriptDir $ScriptDir -Message $Message -RetentionDays $LogRetentionDays
}

function Initialize-PowerApi {
    if ("TelegramPowerMonitor.NativePower" -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TelegramPowerMonitor {
    public static class NativePower {
        [StructLayout(LayoutKind.Sequential)]
        public struct SYSTEM_POWER_INFORMATION {
            public uint MaxIdlenessAllowed;
            public uint Idleness;
            public uint TimeRemaining;
            public byte CoolingMode;
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
    }
}
'@
}

function Get-WindowsPowerCountdown {
    $status = [uint32]0
    $info = [TelegramPowerMonitor.NativePower]::GetSystemPowerInformation([ref]$status)
    $executionStatus = [uint32]0
    $executionState = [TelegramPowerMonitor.NativePower]::GetExecutionState([ref]$executionStatus)

    return [pscustomobject]@{
        Status = $status
        MaxIdlenessAllowed = [uint32]$info.MaxIdlenessAllowed
        Idleness = [uint32]$info.Idleness
        TimeRemaining = [uint32]$info.TimeRemaining
        TimerActive = ($status -eq 0 -and $info.TimeRemaining -ne [uint32]::MaxValue -and $info.TimeRemaining -gt 0)
        ExecutionState = [uint32]$executionState
        ExecutionStateStatus = $executionStatus
        SystemOrDisplayRequired = (($executionState -band 0x3) -ne 0)
    }
}

function Get-LastSleepCounter {
    $status = [uint32]0
    $value = [TelegramPowerMonitor.NativePower]::GetLastSleepTime([ref]$status)
    if ($status -ne 0) { return $null }
    return [uint64]$value
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
    $hasWatcherLock = $watcherMutex.WaitOne(0)
    if (-not $hasWatcherLock) {
        if (-not $ProbeOnce) { Write-WatcherLog "WATCHER_SKIP Another watcher instance is already running" }
        exit 0
    }

    if ($ProbeOnce) {
        Get-WindowsPowerCountdown | Format-List
        exit 0
    }

    Write-WatcherLog "WATCHER_STARTED PreSleepSeconds=$PreSleepSeconds MaxProbeIntervalSeconds=$MaxProbeIntervalSeconds"
    $armed = $true
    $cooldownUntil = [datetimeoffset]::MinValue

    while ($true) {
        $power = Get-WindowsPowerCountdown
        if ($power.Status -ne 0) {
            Write-WatcherLog "POWER_API_ERROR Status=$($power.Status)"
            Start-Sleep -Seconds 30
            continue
        }

        if (-not $power.TimerActive -or $power.SystemOrDisplayRequired) {
            if ([datetimeoffset]::Now -ge $cooldownUntil) { $armed = $true }
            Start-Sleep -Seconds ([math]::Min(30, $MaxProbeIntervalSeconds))
            continue
        }

        $remaining = [int]$power.TimeRemaining
        if (-not $armed) {
            if ([datetimeoffset]::Now -ge $cooldownUntil -and $remaining -gt ($PreSleepSeconds + 30)) {
                $armed = $true
            } else {
                Start-Sleep -Seconds ([math]::Min(30, [math]::Max(1, $remaining)))
                continue
            }
        }

        if ($remaining -le $PreSleepSeconds) {
            $cycleId = [guid]::NewGuid().ToString("N")
            $sleepCounterBefore = Get-LastSleepCounter
            $exitCode = Invoke-PreSleepNotification -SecondsRemaining $remaining -CycleId $cycleId
            Write-WatcherLog "PRE_SLEEP_ATTEMPT Cycle=$cycleId RemainingSeconds=$remaining SendExitCode=$exitCode"
            $armed = $false
            $cooldownUntil = [datetimeoffset]::Now.AddSeconds(60)

            # If sleep occurs, this wait is suspended and resumes after wake. Otherwise the cycle is re-evaluated.
            Start-Sleep -Seconds ($PreSleepSeconds + 20)
            $sleepCounterAfter = Get-LastSleepCounter
            if ($sleepCounterBefore -ne $null -and $sleepCounterAfter -ne $null -and $sleepCounterAfter -ne $sleepCounterBefore) {
                Write-WatcherLog "PRE_SLEEP_CONFIRMED Cycle=$cycleId"
            } else {
                Write-WatcherLog "PRE_SLEEP_NOT_CONFIRMED Cycle=$cycleId; waiting for a fresh Windows countdown"
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
    if ($hasWatcherLock) {
        try { $watcherMutex.ReleaseMutex() } catch {}
    }
    $watcherMutex.Dispose()
}
