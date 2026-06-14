<#
  select-device.ps1
  Discovers every Particle device connected to this PC over serial, enriches each
  with its cloud name / online status / Device OS version, prints a numbered table,
  and lets you pick one. Writes the chosen COM_PORT and DEVICE_ID to -OutFile so the
  calling batch can load them.

  Single device  -> auto-selected (no menu).
  Standalone:    powershell -NoProfile -ExecutionPolicy Bypass -File .\select-device.ps1 -OutFile sel.env
#>
param(
  [Parameter(Mandatory=$true)][string]$OutFile
)
$ErrorActionPreference = 'Stop'

# --- 1. devices connected via serial --------------------------------------
$serial = & particle serial list 2>$null
$connected = @()
foreach ($line in $serial) {
  if ($line -match '(COM\d+)\s*-\s*(.+?)\s*-\s*([0-9a-fA-F]{24})') {
    $connected += [pscustomobject]@{ Port = $matches[1]; Type = $matches[2].Trim(); DeviceId = $matches[3].ToLower() }
  }
}
if ($connected.Count -eq 0) { Write-Host 'No devices found via serial. Is one plugged in?'; exit 3 }

# --- 2. devices owned by this account (cloud) -----------------------------
$cloud = @{}
try {
  $cfg = Get-Content -Raw (Join-Path $env:USERPROFILE '.particle\particle.config.json') | ConvertFrom-Json
  $devs = Invoke-RestMethod -Uri ("https://api.particle.io/v1/devices?access_token={0}" -f $cfg.access_token)
  foreach ($d in $devs) { $cloud[$d.id.ToLower()] = $d }
} catch { Write-Warning "Could not fetch cloud device list (name/online may be blank): $_" }

# --- 3. enrich each connected device --------------------------------------
$rows = @()
foreach ($c in $connected) {
  # Device OS version straight from the device over serial (works regardless of ownership)
  $os = ''
  $sp = $null
  try {
    $sp = New-Object System.IO.Ports.SerialPort($c.Port, 9600, 'None', 8, 'one')
    $sp.ReadTimeout = 1500; $sp.WriteTimeout = 1500
    $sp.Open(); Start-Sleep -Milliseconds 300; $sp.DiscardInBuffer()
    $sp.Write('i'); Start-Sleep -Milliseconds 600
    $info = $sp.ReadExisting()
    if ($info -match '"sysVersion":"([^"]+)"') { $os = $matches[1] }
  } catch { } finally { if ($sp -and $sp.IsOpen) { $sp.Close() } }

  $cd = $cloud[$c.DeviceId]
  if ($cd) {
    if (-not $os) { $os = [string]$cd.system_firmware_version }
    $name   = if ($cd.name) { [string]$cd.name } else { '(unnamed)' }
    $online = if ($cd.online) { 'online' } else { 'offline' }
  } else {
    $name = '(not in your account)'
    $online = '-'
  }
  if (-not $os) { $os = '?' }
  $rows += [pscustomobject]@{ Port = $c.Port; DeviceId = $c.DeviceId; Type = $c.Type; Name = $name; OS = $os; Online = $online }
}

# --- 4. select ------------------------------------------------------------
if ($rows.Count -eq 1) {
  $sel = $rows[0]
  Write-Host ("Single device connected: {0}  {1}" -f $sel.DeviceId, $sel.Name)
} else {
  Write-Host ''
  Write-Host ('  {0,-2} {1,-6} {2,-26} {3,-28} {4,-10} {5}' -f '#','Port','Device ID','Name','OS','Status')
  Write-Host ('  {0,-2} {1,-6} {2,-26} {3,-28} {4,-10} {5}' -f '--','------','--------------------------','----------------------------','----------','------')
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    Write-Host ('  {0,-2} {1,-6} {2,-26} {3,-28} {4,-10} {5}' -f ($i + 1), $r.Port, $r.DeviceId, $r.Name, $r.OS, $r.Online)
  }
  Write-Host ''
  do {
    $ans = Read-Host 'Select device number'
    $idx = 0
    $ok = [int]::TryParse($ans, [ref]$idx)
  } while (-not $ok -or $idx -lt 1 -or $idx -gt $rows.Count)
  $sel = $rows[$idx - 1]
}

# --- 5. hand the choice back to the batch ---------------------------------
"COM_PORT=$($sel.Port)`r`nDEVICE_ID=$($sel.DeviceId)" | Set-Content -Encoding ASCII -Path $OutFile
Write-Host ("Selected {0} on {1}" -f $sel.DeviceId, $sel.Port)
exit 0
