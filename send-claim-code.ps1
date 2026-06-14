<#
  send-claim-code.ps1
  Generates a claim code on YOUR Particle account and pushes it to a Photon
  that is in listening mode (blinking blue) over serial, using the documented
  'C' -> "Enter 63-digit claim code:" -> code + newline protocol.

  Called by claim-photon.bat, but can be run standalone:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\send-claim-code.ps1 -Port COM26

  Reads the access token from %USERPROFILE%\.particle\particle.config.json
  (i.e. whatever account `particle login` is using).
#>
param(
  [Parameter(Mandatory=$true)][string]$Port,
  [int]$Baud = 9600
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

# --- open serial and push the claim code ---
$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, 'None', 8, 'one')
$sp.ReadTimeout  = 2500
$sp.WriteTimeout = 2500
try {
  $sp.Open()
  Start-Sleep -Milliseconds 400
  $sp.DiscardInBuffer()

  # sanity: confirm the device answers the listening-mode interface
  $sp.Write('i'); Start-Sleep -Milliseconds 700
  $info = ''
  try { $info = $sp.ReadExisting() } catch {}
  if ($info -notmatch 'deviceId') {
    Write-Warning "Device did not return info JSON - is it in listening mode (blinking blue) on $Port?"
  } else {
    Write-Host "[claim] device is in listening mode."
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
  try { $confirm = $sp.ReadExisting() } catch { $confirm = '<port dropped after send>' }
  Write-Host ("[claim] device replied: {0}" -f ($confirm -replace "`r?`n", ' | '))

  if ($confirm -match 'Claim code set to') {
    Write-Host "[claim] SUCCESS: claim code stored on device."
    exit 0
  } else {
    Write-Warning "Could not confirm 'Claim code set to' - re-check listening mode and retry."
    exit 2
  }
}
finally {
  if ($sp.IsOpen) { $sp.Close() }
}
