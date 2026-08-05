param(
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5,

    # Disable AutoLogon instead of enabling it.
    [switch]$Disable,

    # Enable AutoLogon.
    [switch]$Enable,

    # Only toggle the AutoAdminLogon registry flag ("0" or "1") without re-prompting or deleting secrets.
    [switch]$SetFlagOnly,

    # Skip the interactive prompt and do not check if already configured.
    # Only used by install.ps1 to call this script non-interactively when the
    # operator explicitly passed -SetupAutologon.
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

$AutologonExePath = Join-Path $ScriptDir "Autologon.exe"
$WinlogonRegPath  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$AutoLogonMarkerPath = Join-Path $TelegramLogRuntimeDir "autologon-managed.json"

function Get-AutologonExe {
    if (Test-Path -LiteralPath $AutologonExePath) {
        return $AutologonExePath
    }

    Write-Host "Autologon.exe not found — downloading from Sysinternals..."
    $downloadUrl = "https://live.sysinternals.com/Autologon.exe"
    $tempPath = "$AutologonExePath.tmp"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempPath -UseBasicParsing -TimeoutSec 30
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw "Could not download Autologon.exe: $($_.Exception.Message)"
    }

    # Verify Authenticode signature — the file is signed by Microsoft.
    $sig = Get-AuthenticodeSignature -FilePath $tempPath
    if ($sig.Status -ne "Valid") {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw "Autologon.exe signature is not valid (status: $($sig.Status)). File removed."
    }
    if ($sig.SignerCertificate.Subject -notmatch "Microsoft") {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw "Autologon.exe is not signed by Microsoft (subject: $($sig.SignerCertificate.Subject)). File removed."
    }

    Move-Item -LiteralPath $tempPath -Destination $AutologonExePath -Force
    Write-Host "Autologon.exe downloaded and signature verified."
    return $AutologonExePath
}

function Get-WinlogonProperty {
    param([string]$Name)
    try {
        return (Get-ItemProperty -Path $WinlogonRegPath -Name $Name -ErrorAction SilentlyContinue).$Name
    } catch {
        return $null
    }
}

function Test-AppManagedAutoLogon {
    return (Test-Path -LiteralPath $AutoLogonMarkerPath)
}

function Write-AutoLogonMarker {
    New-Item -ItemType Directory -Path $TelegramLogRuntimeDir -Force | Out-Null
    [ordered]@{
        Schema = 1
        User = [string](Get-WinlogonProperty -Name "DefaultUserName")
        ConfiguredAt = [datetimeoffset]::Now.ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $AutoLogonMarkerPath -Encoding UTF8 -Force
}

function Clear-AutoLogonLsaSecret {
    if (-not ("TelegramPowerMonitor.AutoLogonLsa" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TelegramPowerMonitor {
    public static class AutoLogonLsa {
        [StructLayout(LayoutKind.Sequential)]
        private struct LSA_OBJECT_ATTRIBUTES {
            public uint Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LSA_UNICODE_STRING {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [DllImport("advapi32.dll")]
        private static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES objectAttributes, uint desiredAccess, out IntPtr policyHandle);
        [DllImport("advapi32.dll")]
        private static extern uint LsaStorePrivateData(IntPtr policyHandle, ref LSA_UNICODE_STRING keyName, IntPtr privateData);
        [DllImport("advapi32.dll")]
        private static extern uint LsaNtStatusToWinError(uint status);
        [DllImport("advapi32.dll")]
        private static extern uint LsaClose(IntPtr policyHandle);

        // POLICY_CREATE_SECRET = 0x20. Passing NULL privateData removes the
        // DefaultPassword LSA secret documented for protected AutoLogon.
        public static uint ClearDefaultPassword() {
            var attributes = new LSA_OBJECT_ATTRIBUTES();
            attributes.Length = (uint)Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
            IntPtr policyHandle;
            uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x20, out policyHandle);
            if (status != 0) return LsaNtStatusToWinError(status);

            IntPtr nameBuffer = Marshal.StringToHGlobalUni("DefaultPassword");
            try {
                var name = new LSA_UNICODE_STRING();
                name.Length = (ushort)("DefaultPassword".Length * sizeof(char));
                name.MaximumLength = (ushort)(name.Length + sizeof(char));
                name.Buffer = nameBuffer;
                status = LsaStorePrivateData(policyHandle, ref name, IntPtr.Zero);
                return status == 0 ? 0 : LsaNtStatusToWinError(status);
            } finally {
                Marshal.FreeHGlobal(nameBuffer);
                LsaClose(policyHandle);
            }
        }
    }
}
'@
    }

    $win32Error = [TelegramPowerMonitor.AutoLogonLsa]::ClearDefaultPassword()
    if ($win32Error -ne 0) {
        throw "Windows could not clear the AutoLogon LSA secret (Win32 error $win32Error)."
    }
}

# ── TOGGLE FLAG ONLY ──────────────────────────────────────────────────────────
if ($SetFlagOnly) {
    if ($Enable -and $Disable) {
        throw "Cannot specify both -Enable and -Disable."
    }
    if (-not $Enable -and -not $Disable) {
        throw "Must specify either -Enable or -Disable with -SetFlagOnly."
    }

    if (-not (Test-TelegramLogAdmin)) {
        throw "Administrator rights are required to change the AutoLogon flag."
    }
    if (-not (Test-AppManagedAutoLogon)) {
        throw "AutoLogon has not been configured by this app. Run setup-autologon.ps1 interactively first."
    }

    $newValue = if ($Enable) { "1" } else { "0" }
    $userName = Get-WinlogonProperty -Name "DefaultUserName"
    Set-ItemProperty -Path $WinlogonRegPath -Name "AutoAdminLogon" -Value $newValue -ErrorAction Stop
    if ((Get-WinlogonProperty -Name "AutoAdminLogon") -ne $newValue) {
        throw "Windows did not persist the requested AutoAdminLogon state."
    }
    $stateText = if ($Enable) { "enabled" } else { "disabled" }
    Write-Host "AutoAdminLogon flag set to $newValue ($stateText) for user: $userName"
    exit 0
}

# ── DISABLE ────────────────────────────────────────────────────────────────────
if ($Disable) {
    if (Test-AppManagedAutoLogon) {
        $username = [string](Get-WinlogonProperty -Name "DefaultUserName")

        Set-ItemProperty -Path $WinlogonRegPath -Name "AutoAdminLogon" -Value "0" -ErrorAction Stop
        if ((Get-WinlogonProperty -Name "AutoAdminLogon") -eq "1") {
            throw "Windows still reports AutoAdminLogon enabled after cleanup."
        }
        Clear-AutoLogonLsaSecret
        Remove-ItemProperty -Path $WinlogonRegPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinlogonRegPath -Name "DefaultUserName" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinlogonRegPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $AutoLogonMarkerPath -Force -ErrorAction Stop
        Write-Host "AutoLogon disabled for user: $username"
    } else {
        Write-Host "No AutoLogon configuration managed by this app was found - nothing to do."
    }

    exit 0
}

# ── ENABLE ─────────────────────────────────────────────────────────────────────
if (-not (Test-TelegramLogAdmin)) {
    throw "Administrator rights are required to configure Windows AutoLogon."
}

$autologonExe = Get-AutologonExe

$currentValue  = Get-WinlogonProperty "AutoAdminLogon"
$configuredUser = [string](Get-WinlogonProperty "DefaultUserName")

if (-not $Silent -and $currentValue -eq "1" -and -not [string]::IsNullOrWhiteSpace($configuredUser)) {
    Write-Host "AutoLogon is already configured for user: $configuredUser"
    $choice = Read-Host "Reconfigure with a new password? (y/N)"
    if ($choice -notmatch '^y(es)?$') {
        Write-Host "Skipped. Existing AutoLogon configuration unchanged."
        exit 0
    }
}

$currentUser   = $env:USERNAME
$currentDomain = if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) {
    $env:USERDOMAIN
} else {
    "."
}

Write-Host ""
Write-Host "Configuring AutoLogon: user=$currentUser  domain=$currentDomain"
Write-Host "The password will be stored encrypted in Windows LSA Secrets (not plaintext)."
Write-Host ""

$securePassword = Read-Host -Prompt "Windows password for '$currentUser'" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $securePassword = $null
}

try {
    & $autologonExe /AcceptEula $currentUser $currentDomain $plainPassword 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Autologon.exe exited with code $LASTEXITCODE." }
    if ((Get-WinlogonProperty -Name "AutoAdminLogon") -ne "1") {
        throw "Windows did not enable AutoAdminLogon after configuration."
    }
    Write-AutoLogonMarker
} finally {
    # Wipe the plaintext string from memory as soon as possible.
    $plainPassword = $null
    [GC]::Collect()
}

Write-Host ""
Write-Host "AutoLogon configured. Windows will log in automatically as '$currentUser' on the next boot."
Write-Host "To disable later: setup-autologon.ps1 -Disable"
