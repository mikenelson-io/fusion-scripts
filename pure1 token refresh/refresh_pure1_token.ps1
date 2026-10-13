# =============================================================================
# refresh_pure1_token.ps1
# Windows PowerShell equivalent of refresh_pure1_token.sh
#
# Regenerates a Pure1 API access token and exports it system-wide so that
# Claude Desktop, VSCode, Augment, and any new shell session can consume it
# without interruption.
#
# What this script does:
#   1. Mints a fresh Bearer token with pure1_token_factory.py, using the
#      application ID and encrypted private key protected by Windows DPAPI
#   2. Validates the token against the Pure1 API (/api/1.0/arrays)
#   3. Writes the token to ~/.pure1_token.env  (cross-tool compatible)
#   4. Sets PURE1_ACCESS_TOKEN at User scope in the Windows registry
#      so Claude Desktop, VSCode, and Augment pick it up on next launch
#
# Usage:
#   .\refresh_pure1_token.ps1                      # refresh (what Task Scheduler runs)
#   .\refresh_pure1_token.ps1 -SetCredentials      # first-time setup, or after
#                                                  # regenerating the API key in Pure1
#   .\refresh_pure1_token.ps1 -SetCredentials -ApiKeyId pure1:apikey:XXXX -KeyPath new.pem
#
# -SetCredentials encrypts the private key with a random passphrase, stores
# the passphrase and application ID with DPAPI (readable only by this Windows
# user on this machine), and verifies the pair with Pure1 before replacing
# anything. Existing credentials are left untouched if the new ones are rejected.
#
# Automatic scheduling is handled by setup_windows_task.ps1
# =============================================================================

[CmdletBinding()]
param(
    [switch]$SetCredentials,
    [string]$ApiKeyId,
    [string]$KeyPath
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Host "This script needs Windows DPAPI. On macOS or Linux, use refresh_pure1_token.sh."
    exit 1
}

# ── Configuration ─────────────────────────────────────────────────────────────
$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$FactoryScript  = Join-Path $ScriptDir "pure1_token_factory.py"
$PrivateKey     = if ($env:PURE1_PRIVATE_KEY) { $env:PURE1_PRIVATE_KEY } else { Join-Path $ScriptDir "pure1_private_key.enc.pem" }
$CredentialFile = Join-Path $ScriptDir "pure1_credentials.xml"
$OutputEnv      = Join-Path $env:USERPROFILE ".pure1_token.env"
$LogFile        = Join-Path $ScriptDir "pure1_token_refresh.log"
$EnvVarName     = "PURE1_ACCESS_TOKEN"
$ValidationUrl  = "https://api.pure1.purestorage.com/api/1.0/arrays"
$KeepBackups    = 5
# ──────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Stop-WithError {
    param([string]$Message)
    Write-Log "ERROR: $Message"
    exit 1
}

# UTF-8 without a BOM. Windows PowerShell 5.1's -Encoding UTF8 adds one,
# which breaks JSON parsers and the first line of a sourced env file.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-PlainText {
    param([securestring]$Secure)
    [System.Net.NetworkCredential]::new('', $Secure).Password
}

# ── Credential store (DPAPI) ──────────────────────────────────────────────────
# Export-Clixml encrypts SecureStrings with DPAPI, tied to this user and machine.
function Get-StoredCredential {
    if (-not (Test-Path $CredentialFile)) { return $null }
    $stored = Import-Clixml -Path $CredentialFile
    [pscustomobject]@{
        ApiKeyId   = ConvertTo-PlainText $stored.ApiKeyId
        Passphrase = ConvertTo-PlainText $stored.Passphrase
    }
}

function Save-StoredCredential {
    param([string]$Id, [string]$Passphrase)
    [pscustomobject]@{
        ApiKeyId   = ConvertTo-SecureString $Id -AsPlainText -Force
        Passphrase = ConvertTo-SecureString $Passphrase -AsPlainText -Force
    } | Export-Clixml -Path $CredentialFile
}

# ── Python helpers ────────────────────────────────────────────────────────────
# Secrets reach Python on stdin, never as arguments, so they don't show in
# process listings. The code below uses single quotes only, because Windows
# PowerShell 5.1 mangles embedded double quotes in native-command arguments.
$MintCode = @'
import sys
sys.path.insert(0, sys.argv[1])
import pure1_token_factory as factory
password = sys.stdin.read().strip() or None
key = factory.get_private_key(sys.argv[3], password)
print(factory.get_access_token(factory.generate_id_token(sys.argv[2], key)))
'@

$EncryptCode = @'
import sys
from cryptography.hazmat.primitives import serialization as ser
src, dst = sys.argv[1], sys.argv[2]
lines = sys.stdin.read().splitlines() + ['', '']
new_pw, old_pw = lines[0].encode(), (lines[1].encode() or None)
key = ser.load_pem_private_key(open(src, 'rb').read(), password=old_pw)
with open(dst, 'wb') as f:
    f.write(key.private_bytes(ser.Encoding.PEM, ser.PrivateFormat.PKCS8, ser.BestAvailableEncryption(new_pw)))
'@

# Runs Python with $Stdin piped in; returns stdout, sends stderr to the log.
# Native stderr must not trip $ErrorActionPreference = Stop in PowerShell 5.1.
function Invoke-Python {
    param([string]$Code, [string[]]$Arguments, [string]$Stdin)
    $ErrorActionPreference = "Continue"
    $output = $Stdin | & $script:PythonCmd -c $Code @Arguments 2>> $LogFile
    if ($LASTEXITCODE -ne 0) { return $null }
    ($output | Out-String).Trim()
}

function New-AccessToken {
    param([string]$Key, [string]$Passphrase, [string]$Id)
    Invoke-Python -Code $MintCode -Arguments @($ScriptDir, $Id, $Key) -Stdin $Passphrase
}

function New-Passphrase {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Test-KeyEncrypted {
    param([string]$Path)
    (Get-Content -Path $Path -Raw) -match 'ENCRYPTED'
}

Write-Log "════════════════════════════════════════"
Write-Log "Starting Pure1 token refresh..."

# ── Pre-flight ────────────────────────────────────────────────────────────────
if (-not (Test-Path $FactoryScript)) {
    Stop-WithError "Token factory script not found at $FactoryScript"
}

# Support both 'python3' (preferred) and 'python' (fallback for Windows PATH setups)
$script:PythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }

# ── Optional: store new credentials ──────────────────────────────────────────
if ($SetCredentials) {
    if (-not $ApiKeyId) { $ApiKeyId = Read-Host "Pure1 application ID (pure1:apikey:...)" }
    if ($ApiKeyId -notmatch '^pure1:apikey:[A-Za-z0-9]+$') {
        Stop-WithError "That doesn't look like a Pure1 application ID: '$ApiKeyId'"
    }
    if (-not $KeyPath) { $KeyPath = Read-Host "Path to the private key registered with that ID" }
    if (-not (Test-Path $KeyPath)) { Stop-WithError "Private key not found: $KeyPath" }
    $KeyPath = (Resolve-Path $KeyPath).Path

    $sourcePass = ""
    if (Test-KeyEncrypted $KeyPath) {
        $sourcePass = ConvertTo-PlainText (Read-Host "Passphrase for $KeyPath" -AsSecureString)
    }

    # Encrypt to a temp file first; nothing is replaced until Pure1 accepts it.
    $newPass = New-Passphrase
    $staged  = Join-Path $ScriptDir ".pure1_key.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $null = Invoke-Python -Code $EncryptCode -Arguments @($KeyPath, $staged) -Stdin "$newPass`n$sourcePass"
        if (-not (Test-Path $staged)) { Stop-WithError "Could not read or encrypt $KeyPath (wrong passphrase?)." }

        Write-Log "Verifying new credentials with Pure1..."
        if (-not (New-AccessToken -Key $staged -Passphrase $newPass -Id $ApiKeyId)) {
            Stop-WithError "Pure1 rejected the new ID/key pair. Existing credentials left unchanged."
        }

        Save-StoredCredential -Id $ApiKeyId -Passphrase $newPass
        Move-Item -Path $staged -Destination $PrivateKey -Force
    }
    finally {
        if (Test-Path $staged) { Remove-Item $staged -Force }
    }
    Write-Log "Credentials updated: ID and passphrase in $CredentialFile (DPAPI), encrypted key at $PrivateKey."
    Write-Log "The unencrypted key at $KeyPath is no longer used. Delete it or move it offline."
}

# ── Load credentials ──────────────────────────────────────────────────────────
if (-not (Test-Path $PrivateKey)) { Stop-WithError "No private key at $PrivateKey. Run: .\refresh_pure1_token.ps1 -SetCredentials" }
$stored = Get-StoredCredential
$ApiKey = if ($env:PURE1_API_KEY) { $env:PURE1_API_KEY } elseif ($stored) { $stored.ApiKeyId } else { $null }
if (-not $ApiKey) { Stop-WithError "No stored Pure1 application ID. Run: .\refresh_pure1_token.ps1 -SetCredentials" }

$passphrase = ""
if (Test-KeyEncrypted $PrivateKey) {
    if (-not $stored -or -not $stored.Passphrase) {
        Stop-WithError "Key is encrypted but no passphrase is stored. Run: .\refresh_pure1_token.ps1 -SetCredentials"
    }
    $passphrase = $stored.Passphrase
} else {
    Write-Log "WARNING: $PrivateKey is not encrypted. Run -SetCredentials to encrypt it."
}

# ── Step 1: Generate the token ────────────────────────────────────────────────
Write-Log "Generating new access token..."
$AccessToken = New-AccessToken -Key $PrivateKey -Passphrase $passphrase -Id $ApiKey
Remove-Variable passphrase, stored

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    Stop-WithError "Token generation failed (see log). Token NOT updated."
}

$preview = $AccessToken.Substring(0, [Math]::Min(20, $AccessToken.Length))
Write-Log "Token generated successfully (preview: ${preview}...)"

# ── Step 2: Validate the token against the Pure1 API ─────────────────────────
Write-Log "Validating token against $ValidationUrl ..."

# Works on both Windows PowerShell 5.1 (WebException) and PowerShell 7
# (HttpResponseException): both expose the HTTP status on .Exception.Response.
$statusCode = $null
try {
    $response = Invoke-WebRequest `
        -Uri $ValidationUrl `
        -Headers @{ Authorization = "Bearer $AccessToken" } `
        -UseBasicParsing `
        -ErrorAction Stop
    $statusCode = [int]$response.StatusCode
}
catch {
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    else {
        Write-Log "WARNING: Network/connection error during validation: $($_.Exception.Message)"
        Write-Log "This is likely an environment or network issue, not a bad token."
        Write-Log "Proceeding with token write, but verify connectivity to Pure1 API."
        $statusCode = 0
    }
}

switch ($statusCode) {
    200 {
        Write-Log "Validation PASSED (HTTP 200) — token is valid and authorized."
    }
    { $_ -in @(401, 403) } {
        Write-Log "Validation FAILED (HTTP $statusCode) — token is invalid, expired, or not authorized."
        Write-Log "The existing token in $OutputEnv has NOT been overwritten."
        exit 1
    }
    { $_ -ge 500 } {
        Write-Log "WARNING: Validation inconclusive (HTTP $statusCode) — server/network error."
        Write-Log "This is likely an environment or network issue, not a bad token."
        Write-Log "Proceeding with token write, but verify connectivity to Pure1 API."
    }
    default {
        Write-Log "WARNING: Unexpected HTTP status '$statusCode' during validation."
        Write-Log "Proceeding with token write — check logs if issues arise."
    }
}

# ── Step 3: Write ~/.pure1_token.env ──────────────────────────────────────────
# Written in bash-compatible `export KEY="VALUE"` format so the same file
# can be sourced on macOS/Linux and read by VSCode, Augment, and other tools.
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$envContent = @"
# Pure1 API Access Token
# Auto-generated by refresh_pure1_token.ps1
# Last refreshed: $timestamp
# Token expires approximately 10 hours after generation.
#
# PowerShell usage:
#   `$env:PURE1_ACCESS_TOKEN = (Get-Content ~/.pure1_token.env | Select-String 'ACCESS_TOKEN' | ForEach-Object { (`$_ -split '"')[1] })
#
export ${EnvVarName}="$AccessToken"

"@
Write-Utf8NoBom -Path $OutputEnv -Content $envContent
Write-Log "Token written to: $OutputEnv"

# ── Step 4: Set at User scope in Windows registry ─────────────────────────────
# This persists across reboots and is inherited by all new process launches,
# including Claude Desktop, VSCode, and Augment.
[System.Environment]::SetEnvironmentVariable($EnvVarName, $AccessToken, "User")
Write-Log "PURE1_ACCESS_TOKEN set at User scope in Windows registry."
Write-Log "Due to a limitation in the Windows OS, the updated variable is not seen by any currently running applications. Claude Desktop, VSCode, and Augment will use the new token on next launch."

# ── Step 5: Export into the current PowerShell session ────────────────────────
Set-Item -Path "Env:$EnvVarName" -Value $AccessToken
Write-Log "PURE1_ACCESS_TOKEN exported to current session."

# ── Step 6: Self-heal the Claude Desktop MCP config ────────────────────────────
# If the "Pure1 API" entry in claude_desktop_config.json is missing (wiped by
# another tool, a Desktop update, a bad manual edit) or holds a stale token,
# rewrite it. This makes both token expiry AND config drift self-correcting.
$ClaudeConfigPath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
if (Test-Path $ClaudeConfigPath) {
    Write-Log "Checking Claude Desktop config for a healthy Pure1 API entry..."
    $configRaw = Get-Content $ClaudeConfigPath -Raw
    $config = $configRaw | ConvertFrom-Json

    if (-not ($config.PSObject.Properties.Name -contains "mcpServers")) {
        $config | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([PSCustomObject]@{})
    }

    $desired = [PSCustomObject]@{
        command = "npx"
        args    = @("-y", "mcp-remote", "https://api.pure1.purestorage.com/mcp", "--header", "Authorization:`${AUTHORIZATION_HEADER}")
        env     = [PSCustomObject]@{ AUTHORIZATION_HEADER = " Bearer $AccessToken" }
    }

    $existingProp = $config.mcpServers.PSObject.Properties["Pure1 API"]
    $existingJson = if ($existingProp) { $existingProp.Value | ConvertTo-Json -Depth 10 -Compress } else { $null }
    $desiredJson  = $desired | ConvertTo-Json -Depth 10 -Compress

    if ($existingJson -ne $desiredJson) {
        $backup = "$ClaudeConfigPath.bak.$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item $ClaudeConfigPath $backup -Force
        if ($existingProp) {
            $config.mcpServers."Pure1 API" = $desired
        } else {
            $config.mcpServers | Add-Member -NotePropertyName "Pure1 API" -NotePropertyValue $desired
        }
        Write-Utf8NoBom -Path $ClaudeConfigPath -Content ($config | ConvertTo-Json -Depth 10)
        Write-Log "Pure1 API entry restored/updated in Claude Desktop config (backup: $backup)."
        Write-Log "Restart Claude Desktop to pick up the change."
    } else {
        Write-Log "Claude Desktop config already up to date — no changes needed."
    }

    # Each backup holds the token of its day; keep only the newest few.
    Get-ChildItem -Path (Split-Path $ClaudeConfigPath) -Filter "claude_desktop_config.json.bak.*" |
        Where-Object { $_.Name -match '\.bak\.\d{14}$' } |
        Sort-Object Name -Descending |
        Select-Object -Skip $KeepBackups |
        Remove-Item -Force
} else {
    Write-Log "WARNING: Claude Desktop config not found at $ClaudeConfigPath — skipping self-heal."
}

Write-Log "Done."
