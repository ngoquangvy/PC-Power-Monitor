param([switch]$Live, [switch]$IsolatedDaemon)

$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'telegram-command-listener.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors.Message -join '; ') }
foreach ($name in @('Invoke-TailscaleRecoveryCli', 'Get-ApprovedTailscaleLoginUrl', 'Get-TailscaleHealth', 'Get-TailscaleLoginReply', 'Test-TailscaleLoginChat', 'Update-TailscaleLoginAlert')) {
    $definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$nativeCli = ${function:Invoke-TailscaleRecoveryCli}
$nativeHealth = ${function:Get-TailscaleHealth}
$TailscaleCli = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$sample = 'https://login.tailscale.com/a/fixture-not-a-real-link'
Assert-True ((Get-ApprovedTailscaleLoginUrl $sample) -eq $sample) 'Official auth links must be accepted.'
foreach ($invalid in @('http://login.tailscale.com/a/x', 'https://login.tailscale.com.evil.test/a/x', 'https://login.tailscale.com@evil.test/a/x', 'https://login.tailscale.com/a/x?redirect=y', "https://login.tailscale.com/a/x`n")) {
    Assert-True (-not (Get-ApprovedTailscaleLoginUrl $invalid)) 'An unsafe URL was accepted.'
}
$message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 42; type = 'private' }; from = [pscustomobject]@{ id = 42 } }
Assert-True (Test-TailscaleLoginChat $message '42') 'Configured private sender must be allowed.'
Assert-True (-not (Test-TailscaleLoginChat $message '43')) 'Other chats must not be allowed.'
$message.from.id = 43
Assert-True (-not (Test-TailscaleLoginChat $message '42')) 'Other senders must not be allowed.'
$message.chat.type = 'group'
$message.from.id = 42
Assert-True (-not (Test-TailscaleLoginChat $message '42')) 'Groups must not receive links.'

$script:status = [pscustomobject]@{ ServiceStatus = 'Running'; BackendState = 'Running'; Online = $true; LoginUrl = $null }
$script:startCount = 0
function Get-TailscaleHealth { param([switch]$IncludeLoginUrl) return $script:status }
function Invoke-TailscaleRecoveryCli {
    param([string]$Operation)
    if ($Operation -eq 'ConnectForLogin') { return [pscustomobject]@{ ExitCode = 0 } }
    Assert-True ($Operation -eq 'StartLogin') 'Unexpected CLI action.'
    $script:startCount++
    $script:status.LoginUrl = $sample
    return [pscustomobject]@{ ExitCode = 0 }
}
$reply = Get-TailscaleLoginReply
Assert-True (-not $reply.HasLoginUrl -and $script:startCount -eq 0) 'A healthy device must not initiate login.'
$script:status.BackendState = 'NeedsMachineAuth'
$reply = Get-TailscaleLoginReply
Assert-True (-not $reply.HasLoginUrl -and $script:startCount -eq 0 -and $reply.Text -match 'approval') 'Approval is distinct from login.'
$script:status.BackendState = 'NeedsLogin'
$script:status.Online = $false
$reply = Get-TailscaleLoginReply
Assert-True ($reply.HasLoginUrl -and $reply.Text.Contains($sample) -and $script:startCount -eq 1) 'NeedsLogin must request and return a link.'
$reply = Get-TailscaleLoginReply
Assert-True ($reply.HasLoginUrl -and $script:startCount -eq 1) 'A pending link must be reused.'
$script:status.LoginUrl = $null
$reply = Get-TailscaleLoginReply
Assert-True (-not $reply.HasLoginUrl -and $script:startCount -eq 1) 'A quick retry must not restart pending authentication.'
$script:status.LoginUrl = 'https://evil.test/a/x'
$reply = Get-TailscaleLoginReply
Assert-True (-not $reply.HasLoginUrl -and $reply.Text -notmatch 'evil\.test') 'Untrusted URLs must never be returned.'

$script:alertCount = 0
function Send-CommandReply { param($Token,$ChatId,$Text) $script:alertCount++ }
function Write-CommandState { param($State) }
function Write-CommandLog { param($Message) }
$alertState = [pscustomobject]@{ TailscaleNeedsLoginAlerted = $false }
Update-TailscaleLoginAlert $alertState 'fixture' '-42'
Assert-True ($script:alertCount -eq 0) 'No recovery alert should be sent to a group.'
Update-TailscaleLoginAlert $alertState 'fixture' '42'
Update-TailscaleLoginAlert $alertState 'fixture' '42'
Assert-True ($script:alertCount -eq 1 -and $alertState.TailscaleNeedsLoginAlerted) 'Alert should be sent once per incident.'
$script:status.BackendState = 'Running'
Update-TailscaleLoginAlert $alertState 'fixture' '42'
$script:status.BackendState = 'NeedsLogin'
Update-TailscaleLoginAlert $alertState 'fixture' '42'
Assert-True ($script:alertCount -eq 2) 'A later incident must produce another alert.'
'Recovery gates, link allowlist, existing/new link, and alert deduplication: PASS'

if ($Live) {
    ${function:Invoke-TailscaleRecoveryCli} = $nativeCli
    ${function:Get-TailscaleHealth} = $nativeHealth
    $health = Get-TailscaleHealth
    Assert-True ($health.BackendState -eq 'Running' -and $health.Online) 'Expected the main Tailscale device to be online.'
    $reply = Get-TailscaleLoginReply
    Assert-True (-not $reply.HasLoginUrl -and $reply.BackendState -eq 'Running') 'Live healthy path must be read-only.'
    'Live Tailscale online path: PASS (no login request sent)'
}

if ($IsolatedDaemon) {
    $socket = '\\.\pipe\tpm-test-' + [guid]::NewGuid().ToString('N')
    $testDir = Join-Path ([IO.Path]::GetTempPath()) ('tpm-tailscale-test-' + [guid]::NewGuid().ToString('N'))
    $daemon = $null
    $watcher = $null
    $script:tailscaleLoginAttempt = $null
    try {
        New-Item -ItemType Directory -Path $testDir | Out-Null
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path (Split-Path -Parent $TailscaleCli) 'tailscaled.exe'
        $info.Arguments = "--windows-mode=dev --tun=userspace-networking --state=mem: --statedir=`"$testDir`" --socket=$socket --port=0 --no-logs-no-support"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $daemon = [Diagnostics.Process]::Start($info)
        $out = $daemon.StandardOutput.ReadToEndAsync()
        $err = $daemon.StandardError.ReadToEndAsync()
        Start-Sleep -Milliseconds 500
        # In Windows dev mode a LocalAPI client keeps the current Windows user
        # selected, like the tray client. Avoid clearing it between CLI calls.
        $info.FileName = $TailscaleCli
        $info.Arguments = "--socket $socket debug watch-ipn"
        $watcher = [Diagnostics.Process]::Start($info)
        $watchOut = $watcher.StandardOutput.ReadToEndAsync()
        $watchErr = $watcher.StandardError.ReadToEndAsync()
        function Invoke-TailscaleRecoveryCli { param($Operation) & $nativeCli -Operation $Operation -TestSocket $socket }
        ${function:Get-TailscaleHealth} = $nativeHealth
        $health = $null
        for ($i=0; $i -lt 8; $i++) {
            if ($daemon.HasExited) { throw 'Isolated Tailscale daemon exited early.' }
            $health = Get-TailscaleHealth
            if ($health.BackendState -eq 'NeedsLogin') { break }
            Start-Sleep -Milliseconds 500
        }
        Assert-True ($health.BackendState -eq 'NeedsLogin') "Isolated backend did not reach NeedsLogin: $($health.BackendState)"
        $reply = Get-TailscaleLoginReply
        # First contact with the coordination server can be slower than the
        # command's bounded wait. Continue observing without starting again.
        if (-not $reply.HasLoginUrl) {
            for ($i=0; $i -lt 20; $i++) {
                Start-Sleep -Seconds 1
                $health = Get-TailscaleHealth -IncludeLoginUrl
                if ($health.LoginUrl) { $reply = Get-TailscaleLoginReply; break }
            }
        }
        Assert-True $reply.HasLoginUrl "Isolated Tailscale did not return a link. Backend=$($reply.BackendState)"
        'Isolated daemon real auth link generation: PASS (link not displayed or approved)'
    } catch {
        if ($daemon -and -not $daemon.HasExited) { $daemon.Kill(); [void]$daemon.WaitForExit(3000) }
        if ($err -and $err.IsCompleted -and -not $err.IsFaulted) {
            $err.Result -split '\r?\n' | Where-Object { $_ -match 'control:|login|error|AuthURL' } | Select-Object -Last 20 | ForEach-Object { $_ -replace 'https?://\S+', '[URL redacted]' -replace '(?i)(nodekey|mkey|tskey|privkey|disco):?[a-z0-9_-]+', '[key redacted]' }
        }
        throw
    } finally {
        if ($watcher) { if (-not $watcher.HasExited) { $watcher.Kill(); [void]$watcher.WaitForExit(3000) }; $watcher.Dispose() }
        if ($daemon) { if (-not $daemon.HasExited) { $daemon.Kill(); [void]$daemon.WaitForExit(3000) }; $daemon.Dispose() }
        $root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolved = [IO.Path]::GetFullPath($testDir)
        if ($resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'tpm-tailscale-test-*' -and (Test-Path -LiteralPath $resolved)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
