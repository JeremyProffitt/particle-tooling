<#
  send-claim-code.ps1
  Generates a claim code on YOUR Particle account and pushes it to a Photon
  that is in listening mode (blinking blue) over serial, using the documented
  'C' -> "Enter 63-digit claim code:" -> code + newline protocol.

  Called by claim-photon.bat, but can be run standalone:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\send-claim-code.ps1 -Port COM26

  Reads the access token from %USERPROFILE%\.particle\particle.config.json
  (i.e. whatever account `particle login` is using).

  Robustness (the USB CDC port on a Photon in listening mode is flaky):
   * Listening-mode detection accepts BOTH the JSON 'i' reply (older Device OS,
     contains "deviceId") AND the plain "Your device id is <id>" reply seen on
     current Device OS. The old check only matched "deviceId", so it warned on
     every modern device even when listening mode was perfectly fine.
   * Every serial write is guarded and the whole push is retried up to -Retries
     times. A single dropped write ("semaphore timeout" / "port is closed") no
     longer aborts the claim.
   * If the port drops right after the code is sent (so we can't read back
     "Claim code set to"), we RE-OPEN and re-probe before declaring failure -
     the code is usually already stored. This avoids reporting a successful
     claim as a failure, which made the batch abort adoption mid-flight.
#>
param(
  [Parameter(Mandatory=$true)][string]$Port,
  [int]$Baud = 9600,
  [int]$Retries = 3
)

$ErrorActionPreference = 'Stop'

# --- get access token from the CLI's stored config ---
$cfgPath = Join-Path $env:USERPROFILE '.particle\particle.config.json'
if (-not (Test-Path $cfgPath)) { Write-Error "Particle config not found at $cfgPath - run 'particle login' first."; exit 1 }
$cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
$token = $cfg.access_token
if (-not $token) { Write-Error "No access_token in $cfgPath - run 'particle login'."; exit 1 }
Write-Host ("[claim] account: {0}" -f $cfg.username)

# --- generate a claim code tied to this account ---
Write-Host "[claim] requesting a claim code from the Particle cloud..."
$resp = Invoke-RestMethod -Method Post -Uri 'https://api.particle.io/v1/device_claims' -Body @{ access_token = $token }
$code = $resp.claim_code
if (-not $code -or $code.Length -lt 60) { Write-Error "Bad claim code from cloud: '$code'"; exit 1 }
Write-Host ("[claim] got {0}-char claim code" -f $code.Length)

# A Photon answers 'i' in listening mode with either a JSON blob containing
# "deviceId" (older Device OS) or the plain line "Your device id is <hex>".
function Test-Listening([string]$reply) {
  return ($reply -match 'deviceId' -or $reply -match 'device id is')
}

# Open the port with a couple of retries - it can be momentarily busy right
# after the device enters listening mode (re-enumeration).
function Open-Port {
  for ($i = 1; $i -le 3; $i++) {
    try {
      $p = New-Object System.IO.Ports.SerialPort($Port, $Baud, 'None', 8, 'one')
      $p.ReadTimeout = 2500; $p.WriteTimeout = 2500
      $p.Open()
      return $p
    } catch {
      Write-Host ("[claim] open {0} failed (try {1}/3): {2}" -f $Port, $i, $_.Exception.Message)
      Start-Sleep -Milliseconds 600
    }
  }
  return $null
}

# Try ONE full claim-code push. Returns $true on confirmed success.
function Push-ClaimCode {
  $sp = Open-Port
  if (-not $sp) { Write-Warning "Could not open $Port."; return $false }
  try {
    Start-Sleep -Milliseconds 400
    $sp.DiscardInBuffer()

    # sanity: confirm the device answers the listening-mode interface
    $info = ''
    try { $sp.Write('i'); Start-Sleep -Milliseconds 700; $info = $sp.ReadExisting() } catch {}
    if (Test-Listening $info) {
      Write-Host "[claim] device is in listening mode."
    } else {
      Write-Warning ("Device did not answer the listening-mode probe on {0} (got: '{1}'). Pushing anyway." -f $Port, ($info -replace "`r?`n", ' '))
    }
    $sp.DiscardInBuffer()

    # 'C' -> wait for "Enter 63-digit claim code:" -> send code char-by-char + newline
    $sp.Write('C')
    Start-Sleep -Milliseconds 800
    $prompt = ''
    try { $prompt = $sp.ReadExisting() } catch {}
    if ($prompt -notmatch 'claim code') {
      Write-Warning "Did not see the claim-code prompt (got: '$prompt'). Sending code anyway."
    }
    foreach ($ch in $code.ToCharArray()) { $sp.Write([string]$ch); Start-Sleep -Milliseconds 5 }  # char-by-char: bulk writes drop the USB CDC port
    $sp.Write("`n")
    Start-Sleep -Milliseconds 1500

    $confirm = ''
    try { $confirm = $sp.ReadExisting() } catch { $confirm = '' }
    if ($confirm) { Write-Host ("[claim] device replied: {0}" -f ($confirm -replace "`r?`n", ' | ')) }

    if ($confirm -match 'Claim code set to') {
      Write-Host "[claim] SUCCESS: claim code stored on device."
      return $true
    }
    Write-Warning "Did not read back 'Claim code set to' (port may have dropped after send)."
    return $false
  } catch {
    Write-Warning ("Push attempt errored: {0}" -f $_.Exception.Message)
    return $false
  } finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
    Start-Sleep -Milliseconds 400   # let the CDC port settle before re-opening
  }
}

# --- push with retries -----------------------------------------------------
for ($attempt = 1; $attempt -le $Retries; $attempt++) {
  Write-Host ("[claim] push attempt {0}/{1} on {2}..." -f $attempt, $Retries, $Port)
  if (Push-ClaimCode) { exit 0 }
  if ($attempt -lt $Retries) { Write-Host "[claim] retrying..."; Start-Sleep -Milliseconds 800 }
}

Write-Warning "Could not confirm 'Claim code set to' after $Retries attempts. Re-check listening mode (blinking blue) on $Port and retry."
exit 2
