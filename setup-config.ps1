param(
    [string]$ConfigPath,
    [switch]$Console,
    [switch]$MigrateLegacy,
    [string]$LegacyConfigPath,
    [switch]$RemoveLegacy
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "common.ps1")

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $installedConfig = Get-TelegramLogConfigCandidate -ScriptDir $ScriptDir
    $ConfigPath = if ($installedConfig) { $installedConfig } else { Join-Path $ScriptDir "config.json" }
}

function Get-ValidationError {
    param([string]$BotToken, [string]$ChatId)

    if ($BotToken -notmatch '^\d{6,15}:[A-Za-z0-9_-]{20,}$') {
        return "Bot token is not in the expected Telegram format."
    }
    if ($ChatId -notmatch '^-?\d+$' -and $ChatId -notmatch '^@[A-Za-z][A-Za-z0-9_]{4,31}$') {
        return "Chat ID must be numeric (for example -1001234567890) or a valid @channel username."
    }
    return $null
}

function Save-TelegramConfig {
    param([string]$BotToken, [string]$ChatId)

    $validationError = Get-ValidationError -BotToken $BotToken -ChatId $ChatId
    if ($validationError) { throw $validationError }

    $parent = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [ordered]@{
        telegramBotToken = $BotToken.Trim()
        telegramChatId = $ChatId.Trim()
    } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Convert-SecureStringToText {
    param([Security.SecureString]$SecureValue)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

if ($MigrateLegacy) {
    if ([string]::IsNullOrWhiteSpace($LegacyConfigPath)) {
        $LegacyConfigPath = Join-Path $ScriptDir "config.ps1"
    }
    if (-not (Test-Path -LiteralPath $LegacyConfigPath)) {
        throw "Legacy config was not found: $LegacyConfigPath"
    }
    . $LegacyConfigPath
    Save-TelegramConfig -BotToken ([string]$TelegramBotToken) -ChatId ([string]$TelegramChatId)
    if ($RemoveLegacy) {
        Remove-Item -LiteralPath $LegacyConfigPath -Force
    }
    Write-Host "Telegram configuration migrated to JSON: $ConfigPath"
    exit 0
}

$existingToken = ""
$existingChatId = ""
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $existing = Read-TelegramLogConfig -Path $ConfigPath
        $existingToken = $existing.TelegramBotToken
        $existingChatId = $existing.TelegramChatId
    } catch {
        # The form can repair a malformed file.
    }
}

function Invoke-ConsoleSetup {
    Write-Host ""
    Write-Host "Telegram Power Monitor settings"
    Write-Host "Config: $ConfigPath"
    $tokenPrompt = if ($existingToken) { "Bot token (leave empty to keep current)" } else { "Bot token" }
    $secureToken = Read-Host $tokenPrompt -AsSecureString
    $token = Convert-SecureStringToText -SecureValue $secureToken
    if ([string]::IsNullOrWhiteSpace($token)) { $token = $existingToken }

    $chatPrompt = if ($existingChatId) { "Chat ID [$existingChatId]" } else { "Chat ID" }
    $chatId = Read-Host $chatPrompt
    if ([string]::IsNullOrWhiteSpace($chatId)) { $chatId = $existingChatId }

    Save-TelegramConfig -BotToken $token -ChatId $chatId
    Write-Host "Settings saved."
}

if ($Console) {
    Invoke-ConsoleSetup
    exit 0
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Telegram Power Monitor - Settings"
    $form.ClientSize = New-Object System.Drawing.Size(520, 245)
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Telegram connection"
    $title.Font = New-Object System.Drawing.Font($title.Font, [Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(20, 15)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $tokenLabel = New-Object System.Windows.Forms.Label
    $tokenLabel.Text = "Bot token:"
    $tokenLabel.Location = New-Object System.Drawing.Point(20, 55)
    $tokenLabel.AutoSize = $true
    $form.Controls.Add($tokenLabel)

    $tokenBox = New-Object System.Windows.Forms.TextBox
    $tokenBox.Location = New-Object System.Drawing.Point(120, 51)
    $tokenBox.Size = New-Object System.Drawing.Size(370, 23)
    $tokenBox.Text = $existingToken
    $tokenBox.UseSystemPasswordChar = $true
    $form.Controls.Add($tokenBox)

    $showToken = New-Object System.Windows.Forms.CheckBox
    $showToken.Text = "Show token"
    $showToken.Location = New-Object System.Drawing.Point(120, 80)
    $showToken.AutoSize = $true
    $showToken.Add_CheckedChanged({ $tokenBox.UseSystemPasswordChar = -not $showToken.Checked })
    $form.Controls.Add($showToken)

    $chatLabel = New-Object System.Windows.Forms.Label
    $chatLabel.Text = "Chat ID:"
    $chatLabel.Location = New-Object System.Drawing.Point(20, 115)
    $chatLabel.AutoSize = $true
    $form.Controls.Add($chatLabel)

    $chatBox = New-Object System.Windows.Forms.TextBox
    $chatBox.Location = New-Object System.Drawing.Point(120, 111)
    $chatBox.Size = New-Object System.Drawing.Size(370, 23)
    $chatBox.Text = $existingChatId
    $form.Controls.Add($chatBox)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(20, 150)
    $statusLabel.Size = New-Object System.Drawing.Size(470, 35)
    $statusLabel.ForeColor = [Drawing.Color]::Firebrick
    $form.Controls.Add($statusLabel)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = "Save"
    $saveButton.Location = New-Object System.Drawing.Point(315, 195)
    $saveButton.Size = New-Object System.Drawing.Size(80, 30)
    $saveButton.Add_Click({
        $errorText = Get-ValidationError -BotToken $tokenBox.Text.Trim() -ChatId $chatBox.Text.Trim()
        if ($errorText) {
            $statusLabel.Text = $errorText
            return
        }
        try {
            Save-TelegramConfig -BotToken $tokenBox.Text -ChatId $chatBox.Text
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(410, 195)
    $cancelButton.Size = New-Object System.Drawing.Size(80, 30)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton
    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { exit 1 }
    exit 0
} catch {
    Write-Warning "Settings form could not be opened; using terminal input instead."
    Invoke-ConsoleSetup
    exit 0
}
