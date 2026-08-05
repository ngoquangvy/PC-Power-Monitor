param(
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

function Write-WakeDisplayLog {
    param([string]$Message)
    Write-TelegramLog -ScriptDir $ScriptDir -Message $Message -RetentionDays $LogRetentionDays
}

try {
    if (-not ("TelegramPowerMonitor.WakeDisplay" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TelegramPowerMonitor {
    public static class WakeDisplay {
        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT {
            public uint Type;
            public MOUSEINPUT Mouse;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        // INPUT_MOUSE = 0; MOUSEEVENTF_MOVE = 0x0001. Move one pixel and
        // immediately return so Windows observes input without clicking or
        // typing into the current application.
        public static bool WakeAndResetIdle() {
            var inputs = new INPUT[2];
            inputs[0].Type = 0;
            inputs[0].Mouse.dx = 1;
            inputs[0].Mouse.dwFlags = 0x0001;
            inputs[1].Type = 0;
            inputs[1].Mouse.dx = -1;
            inputs[1].Mouse.dwFlags = 0x0001;
            return SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) == 2;
        }
    }
}
'@
    }

    if (-not [TelegramPowerMonitor.WakeDisplay]::WakeAndResetIdle()) {
        throw "SendInput did not deliver the wake-display input."
    }

    Write-WakeDisplayLog "WAKE_DISPLAY_OK"
    exit 0
} catch {
    Write-WakeDisplayLog "WAKE_DISPLAY_ERROR Type=$($_.Exception.GetType().Name)"
    exit 1
}
