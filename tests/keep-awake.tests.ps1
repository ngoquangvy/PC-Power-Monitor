param([switch]$NativeSmokeTest)

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'telegram-command-listener.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors.Message -join '; ') }
foreach ($name in @('Read-CommandState', 'Write-CommandState', 'Set-KeepAwakeMode', 'Update-KeepAwakeRequest')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Write-CommandLog { param([string]$Message) }
function Set-KeepAwakeRequest {
    param([bool]$Enabled)
    $script:mockEnabled = $Enabled
    $script:keepAwakeRequest = if ($Enabled) { [pscustomobject]@{ Active = $true } } else { $null }
}
function Test-ActiveRdpSession {
    if ($script:mockQueryFailure) { throw 'Simulated WTS query failure.' }
    return $script:mockRdpConnected
}
$script:mockRdpConnected = $false
$script:mockQueryFailure = $false
$script:rdpConnected = $null
$script:rdpStateUnknown = $false
$script:autoHoldDeadlineTicks = $null
$AutoDisconnectHoldSeconds = 7200
$script:mockClock = [pscustomobject]@{ Now = [datetimeoffset]'2026-10-25T08:00:00+07:00'; Ticks = [double]1000; Frequency = [double]1000 }
function Get-KeepAwakeClock { return $script:mockClock }

$TelegramLogRuntimeDir = Join-Path ([IO.Path]::GetTempPath()) ('keep-awake-test-' + [guid]::NewGuid())
$CommandStatePath = Join-Path $TelegramLogRuntimeDir 'command-state.json'
try {
    $state = Read-CommandState
    Assert-True ($state.KeepAwakeMode -eq 'Auto') 'New installations must default AUTO.'
    $state.NextUpdateOffset = 1234
    Write-CommandState -State $state
    Set-KeepAwakeMode -State $state -Mode On
    Assert-True $script:mockEnabled 'Enable must acquire a request.'
    $reloaded = Read-CommandState
    Assert-True ($reloaded.KeepAwakeEnabled -eq $true) 'Enabled state must survive reload.'
    Assert-True ($reloaded.NextUpdateOffset -eq 1234) 'Commands must preserve the Telegram offset.'
    Set-KeepAwakeMode -State $reloaded -Mode Off
    Assert-True (-not $script:mockEnabled) 'Disable must release the request.'
    Assert-True ((Read-CommandState).KeepAwakeMode -eq 'Off') 'Disabled state must persist.'

    '{"NextUpdateOffset":1234}' | Set-Content -LiteralPath $CommandStatePath -Encoding UTF8
    $migrated = Read-CommandState
    Assert-True ($migrated.KeepAwakeMode -eq 'Auto') 'Legacy state must migrate to AUTO.'
    Assert-True ($migrated.NextUpdateOffset -eq 1234) 'Migration must preserve the Telegram offset.'
    Set-KeepAwakeMode -State $migrated -Mode Off

    $savedStatePath = $CommandStatePath
    $CommandStatePath = Join-Path $TelegramLogRuntimeDir 'missing-parent\state.json'
    $failed = $false
    try { Set-KeepAwakeMode -State $migrated -Mode On } catch { $failed = $true }
    Assert-True $failed 'A failed save must be reported.'
    Assert-True (-not $script:mockEnabled -and $migrated.KeepAwakeMode -eq 'Off') 'A failed save must restore the previous OFF mode.'
    $CommandStatePath = $savedStatePath
    'State migration, enable/disable persistence, and rollback: PASS'

    $script:mockRdpConnected = $true
    Set-KeepAwakeMode -State $migrated -Mode Auto
    Assert-True $script:mockEnabled 'AUTO must hold while RDP is active.'
    $script:mockQueryFailure = $true
    $failed = $false
    try { Update-KeepAwakeRequest -State $migrated } catch { $failed = $true }
    Assert-True ($failed -and $script:mockEnabled) 'Unknown RDP status must retain an existing hold.'
    Set-KeepAwakeMode -State $migrated -Mode Off
    Assert-True (-not $script:mockEnabled) 'Explicit OFF must work even when WTS fails.'
    $script:mockQueryFailure = $false
    Update-KeepAwakeRequest -State $migrated
    Assert-True (-not $script:mockEnabled) 'Explicit OFF must override connected RDP.'
    Set-KeepAwakeMode -State $migrated -Mode Auto
    Assert-True $script:mockEnabled 'Returning to AUTO must acquire a hold for active RDP.'
    $script:mockRdpConnected = $false
    Update-KeepAwakeRequest -State $migrated
    Assert-True $script:mockEnabled 'RDP disconnect must retain AUTO hold.'
    $firstDeadline = $script:autoHoldDeadlineTicks
    $script:mockClock.Ticks = $firstDeadline - 1000
    $script:mockClock.Now = $script:mockClock.Now.AddDays(30)
    Update-KeepAwakeRequest -State $migrated
    Assert-True $script:mockEnabled 'At 1h59m59s, even after a wall-clock jump, the request must remain active.'
    $script:mockClock.Ticks = $firstDeadline
    Update-KeepAwakeRequest -State $migrated
    Assert-True (-not $script:mockEnabled) 'The request may release only at the full two-hour boundary.'
    Update-KeepAwakeRequest -State $migrated
    Assert-True (-not $script:mockEnabled) 'An expired grace must not restart on each poll.'

    $script:mockRdpConnected = $true
    Update-KeepAwakeRequest -State $migrated
    Assert-True ($script:mockEnabled -and $null -eq $script:autoHoldDeadlineTicks) 'Reconnect must cancel the old deadline and hold.'
    $script:mockClock.Ticks += 5000
    $script:mockRdpConnected = $false
    Update-KeepAwakeRequest -State $migrated
    $secondDeadline = $script:autoHoldDeadlineTicks
    Assert-True ($secondDeadline -eq ($script:mockClock.Ticks + 7200000)) 'A second disconnect must start a fresh two-hour interval.'
    $script:mockClock.Ticks += 300000
    Update-KeepAwakeRequest -State $migrated
    Assert-True ($script:autoHoldDeadlineTicks -eq $secondDeadline) 'Repeated disconnected polls must not extend the interval.'
    $script:autoHoldDeadlineTicks = $null
    $script:rdpConnected = $null
    $reloaded = Read-CommandState
    Update-KeepAwakeRequest -State $reloaded
    Assert-True ($script:mockEnabled -and $script:autoHoldDeadlineTicks -eq ($script:mockClock.Ticks + 7200000)) 'A listener restart must start a conservative full grace.'

    $script:mockQueryFailure = $true
    $script:keepAwakeRequest = $null
    try { Update-KeepAwakeRequest -State $migrated } catch {}
    Assert-True $script:mockEnabled 'Unknown RDP on startup must acquire a safety hold.'
    $script:mockQueryFailure = $false
    $script:mockClock.Ticks += 1000
    Update-KeepAwakeRequest -State $migrated
    Assert-True ($script:autoHoldDeadlineTicks -eq ($script:mockClock.Ticks + 7200000)) 'Recovery to disconnected must start a fresh grace.'
    Set-KeepAwakeMode -State $migrated -Mode On
    Update-KeepAwakeRequest -State $migrated
    Assert-True $script:mockEnabled 'Manual ON must hold without RDP.'
    Set-KeepAwakeMode -State $migrated -Mode Off
    'Two-hour boundaries, reconnect, clock jumps, restart, WTS failure, and manual overrides: PASS'

    if ($NativeSmokeTest) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-KeepAwakeRequest' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $rdpDefinition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ActiveRdpSession' }, $true)
        . ([scriptblock]::Create($rdpDefinition.Extent.Text))
        $actualRdp = Test-ActiveRdpSession
        "Windows WTS query: PASS (RdpActive=$actualRdp)"
        $script:keepAwakeRequest = $null
        try {
            Set-KeepAwakeRequest -Enabled $true
            Assert-True $script:keepAwakeRequest.Active 'Windows must accept the power request.'
            $first = $script:keepAwakeRequest
            Set-KeepAwakeRequest -Enabled $true
            Assert-True ([object]::ReferenceEquals($first, $script:keepAwakeRequest)) 'Repeated enable must reuse the request.'
            Set-KeepAwakeRequest -Enabled $false
            Assert-True ($null -eq $script:keepAwakeRequest -and -not $first.Active) 'Disable must stop the worker and release the request.'
            Set-KeepAwakeRequest -Enabled $false
            'Windows native request lifecycle and idempotency: PASS'

            # Exercise the real native worker through the AUTO state machine.
            # Only the clock and RDP observation are simulated; power requests
            # are real and always released in finally.
            function Test-ActiveRdpSession { return $false }
            $script:autoHoldDeadlineTicks = $null
            $script:rdpConnected = $null
            $script:rdpStateUnknown = $false
            $reloaded.KeepAwakeMode = 'Auto'
            Update-KeepAwakeRequest -State $reloaded
            $nativeDeadline = $script:autoHoldDeadlineTicks
            Assert-True $script:keepAwakeRequest.Active 'AUTO disconnect must acquire a real Windows request.'
            $script:mockClock.Ticks = $nativeDeadline - 1
            Update-KeepAwakeRequest -State $reloaded
            Assert-True $script:keepAwakeRequest.Active 'The real request must remain until the last monotonic tick.'
            $script:mockClock.Ticks = $nativeDeadline
            Update-KeepAwakeRequest -State $reloaded
            Assert-True ($null -eq $script:keepAwakeRequest) 'The real request must release at expiry.'
            'AUTO state machine with real Windows requests at deadline boundaries: PASS'
        } finally { Set-KeepAwakeRequest -Enabled $false }
    }
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $cleanupPath = [IO.Path]::GetFullPath($TelegramLogRuntimeDir)
    if (-not $cleanupPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($cleanupPath) -notlike 'keep-awake-test-*') {
        throw 'Refusing to clean a test directory outside the expected temporary path.'
    }
    if (Test-Path -LiteralPath $cleanupPath) { Remove-Item -LiteralPath $cleanupPath -Recurse -Force }
}
