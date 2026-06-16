<#
  photon-manager.ps1
  Inventory every Particle device on USB (serial AND DFU), show a menu, and run
  one of:
    * Auto   - update Device OS on every device in DFU mode (blinking yellow) AND
               claim every unclaimed device in listening mode (blinking blue).
               This is the DEFAULT - just press Enter.
    * Claim ALL claimable devices (anything not already in your account).
    * Update Device OS on ALL connected Photons.
    * Claim a single device chosen by number.

  Device mode (LISTENING / DFU / running) comes from `particle usb list`, which
  lists BOTH serial and DFU devices - the only command that sees a DFU device
  (it has no serial interface). Ownership comes from GET /v1/devices. The serial
  COM port (needed to push a claim code / Wi-Fi) comes from `particle serial list`.

  Reuses send-claim-code.ps1 for the flaky serial claim-code push and
  `particle serial wifi` for Wi-Fi. Wi-Fi creds and options are read from the
  environment (the calling claim-photon.bat exports them from .env):
      WIFI_SSID, WIFI_PASSWORD, WIFI_SECURITY, DEVICE_NAME, DEVICE_ID, SKIP_UPDATE

  Standalone:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\photon-manager.ps1
      # or non-interactive:
      ... .\photon-manager.ps1 -Action auto|claimall|updateall
#>
param(
  [ValidateSet('menu','auto','claimall','updateall')]
  [string]$Action = 'menu'
)
$ErrorActionPreference = 'Stop'
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$claimHelper = Join-Path $here 'send-claim-code.ps1'

# --- config from environment (exported by claim-photon.bat from .env) ------
$Ssid       = $env:WIFI_SSID
$Password   = $env:WIFI_PASSWORD
$Security   = if ($env:WIFI_SECURITY) { $env:WIFI_SECURITY } else { 'WPA2_AES' }
$DeviceName = $env:DEVICE_NAME
$DeviceId   = $env:DEVICE_ID
$SkipUpdate = ($env:SKIP_UPDATE -eq '1')

# ===========================================================================
#  Inventory helpers
# ===========================================================================

# id -> cloud device object, for everything in YOUR account
function Get-CloudDevices {
  $map = @{}
  try {
    $cfg  = Get-Content -Raw (Join-Path $env:USERPROFILE '.particle\particle.config.json') | ConvertFrom-Json
    $devs = Invoke-RestMethod -Uri ("https://api.particle.io/v1/devices?access_token={0}" -f $cfg.access_token)
    foreach ($d in $devs) { $map[$d.id.ToLower()] = $d }
  } catch { Write-Warning "Could not fetch your cloud device list (ownership may be wrong): $_" }
  return $map
}

# id -> COM port, for devices currently exposing a serial interface
function Get-SerialPorts {
  $map = @{}
  foreach ($line in (& particle serial list 2>$null)) {
    if ($line -match '(COM\d+)\s*-\s*.+?\s*-\s*([0-9a-fA-F]{24})') { $map[$matches[2].ToLower()] = $matches[1] }
  }
  return $map
}

# Full inventory: parse `particle usb list` (lines like
#   "<name> [<24-hex-id>] (Photon, LISTENING)"  /  "... (Photon, DFU)"  /  "... (Photon)")
function Get-Inventory {
  $cloud = Get-CloudDevices
  $ports = Get-SerialPorts
  $rows  = @()
  foreach ($line in (& particle usb list 2>$null)) {
    if ($line -match '^(.*?)\s+\[([0-9a-fA-F]{24})\]\s+\((.+)\)\s*$') {
      $id    = $matches[2].ToLower()
      $paren = $matches[3]
      $mode  = if ($paren -match 'DFU') { 'DFU' } elseif ($paren -match 'LISTENING') { 'LISTENING' } else { 'running' }
      $isPhoton = ($paren -match 'Photon')
      $cd    = $cloud[$id]
      $owned = [bool]$cd
      $name  = if ($cd -and $cd.name) { [string]$cd.name } elseif ($owned) { '(unnamed)' } else { '' }
      $rows += [pscustomobject]@{
        Id        = $id
        Name      = $name
        Mode      = $mode
        IsPhoton  = $isPhoton
        Owned     = $owned
        Claimable = ((-not $owned) -and $isPhoton)
        Port      = $ports[$id]
      }
    }
  }
  return ,$rows
}

# ===========================================================================
#  Actions
# ===========================================================================

function Assert-Wifi {
  if (-not $Ssid -or -not $Password) {
    Write-Warning "WIFI_SSID / WIFI_PASSWORD not set in .env - cannot claim (claiming needs Wi-Fi to bring the device online). Skipping claim."
    return $false
  }
  return $true
}

# Update Device OS on one device (particle update can target by id; it enters
# DFU over USB itself when the device is reachable).
function Invoke-UpdateOne($row) {
  Write-Host ""
  Write-Host ("=== Updating Device OS on {0} ({1}) ===" -f $row.Id, $row.Mode)
  & particle update $row.Id
  if ($LASTEXITCODE -ne 0) { Write-Warning ("[{0}] update returned an error." -f $row.Id); return $false }
  return $true
}

# Claim one device: ensure listening mode, push claim code (BEFORE Wi-Fi),
# then set Wi-Fi (which restarts it so it reconnects presenting the code and
# the cloud transfers ownership). Returns the device id on a successful push.
function Invoke-ClaimOne($row) {
  $id   = $row.Id
  $port = $row.Port
  if ($row.Mode -ne 'LISTENING' -or -not $port) {
    Write-Host ("[{0}] not in listening mode - trying 'particle usb start-listening'..." -f $id)
    & particle usb start-listening $id 2>$null | Out-Null
    Start-Sleep -Seconds 3
    $port = (Get-SerialPorts)[$id]
  }
  if (-not $port) {
    Write-Warning ("[{0}] no serial port - put it in listening mode (hold SETUP until blinking blue) and re-run." -f $id)
    return $null
  }

  Write-Host ""
  Write-Host ("=== Claiming {0} on {1} ===" -f $id, $port)
  # claim-code push (separate powershell process so its `exit` can't kill us)
  & powershell -NoProfile -ExecutionPolicy Bypass -File $claimHelper -Port $port
  if ($LASTEXITCODE -ne 0) { Write-Warning ("[{0}] claim-code push failed on {1}." -f $id, $port); return $null }

  # Wi-Fi (restarts the device out of listening mode -> it reconnects + claims)
  $wifi = Join-Path $env:TEMP ("photon_wifi_{0}.json" -f $id)
  @{ network = $Ssid; security = $Security; password = $Password } | ConvertTo-Json | Set-Content -Encoding ASCII $wifi
  Write-Host ("[{0}] sending Wi-Fi (SSID: {1}, {2})..." -f $id, $Ssid, $Security)
  & particle serial wifi --port $port --file $wifi
  $wifiOk = ($LASTEXITCODE -eq 0)
  Remove-Item $wifi -ErrorAction SilentlyContinue
  if (-not $wifiOk) { Write-Warning ("[{0}] Wi-Fi setup failed on {1} - still in listening mode?" -f $id, $port); return $null }

  Write-Host ("[{0}] claim code + Wi-Fi sent; device will restart and reconnect." -f $id)
  return $id
}

# Poll `particle list` until each claimed id shows online, or ~90s elapses.
function Wait-Online([string[]]$ids) {
  if (-not $ids -or $ids.Count -eq 0) { return }
  Write-Host ""
  Write-Host ("[*] Waiting up to ~90s for {0} device(s) to connect and claim..." -f $ids.Count)
  Write-Host "    LED should go: blinking green -> blinking cyan -> breathing cyan."
  $pending  = [System.Collections.ArrayList]@($ids)
  $deadline = (Get-Date).AddSeconds(90)
  while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $list = & particle list 2>$null
    foreach ($id in @($pending)) {
      $line = $list | Where-Object { $_ -match [regex]::Escape($id) } | Select-Object -First 1
      if ($line -and $line -match 'is online') {
        Write-Host ("[OK] {0}" -f $line.Trim())
        if ($DeviceName -and $ids.Count -eq 1) {
          Write-Host ("[*] Renaming to {0}..." -f $DeviceName)
          & particle device rename $id $DeviceName
        }
        $pending.Remove($id) | Out-Null
      }
    }
    if ($pending.Count -gt 0) { Start-Sleep -Seconds 3 }
  }
  foreach ($id in $pending) {
    Write-Warning ("[{0}] not online yet. breathing cyan=ok | breathing green=fix keys (particle keys doctor) | blinking green=Wi-Fi creds." -f $id)
  }
}

# ===========================================================================
#  Action runners (shared by the menu and by -Action)
# ===========================================================================

function Run-Auto($inv) {
  $dfu        = @($inv | Where-Object { $_.IsPhoton -and $_.Mode -eq 'DFU' })
  $listenable = @($inv | Where-Object { $_.Claimable -and $_.Mode -eq 'LISTENING' })

  if ($SkipUpdate) {
    Write-Host "[auto] SKIP_UPDATE=1 - skipping the Device OS update phase."
  } elseif ($dfu.Count -eq 0) {
    Write-Host "[auto] No devices in DFU mode (blinking yellow) - nothing to update."
  } else {
    Write-Host ("[auto] Updating Device OS on {0} DFU device(s)..." -f $dfu.Count)
    foreach ($d in $dfu) { Invoke-UpdateOne $d | Out-Null }
  }

  if ($listenable.Count -eq 0) {
    Write-Host "[auto] No unclaimed devices in listening mode (blinking blue) - nothing to claim."
    return
  }
  if (-not (Assert-Wifi)) { return }
  Write-Host ("[auto] Claiming {0} unclaimed listening device(s)..." -f $listenable.Count)
  $claimed = @()
  foreach ($d in $listenable) { $r = Invoke-ClaimOne $d; if ($r) { $claimed += $r } }
  Wait-Online $claimed

  if (-not $SkipUpdate -and $dfu.Count -gt 0) {
    Write-Host ""
    Write-Host "[auto] NOTE: devices you just updated rebooted out of DFU. If any are unclaimed,"
    Write-Host "       put them in listening mode (blinking blue) and run auto again to claim them."
  }
}

function Run-ClaimAll($inv) {
  $claimable = @($inv | Where-Object { $_.Claimable })
  if ($claimable.Count -eq 0) { Write-Host "Nothing to claim - every connected Photon is already in your account."; return }
  if (-not (Assert-Wifi)) { return }
  Write-Host ("[*] Claiming {0} claimable device(s)..." -f $claimable.Count)
  $claimed = @()
  foreach ($d in $claimable) { $r = Invoke-ClaimOne $d; if ($r) { $claimed += $r } }
  Wait-Online $claimed
}

function Run-UpdateAll($inv) {
  $photons = @($inv | Where-Object { $_.IsPhoton })
  if ($photons.Count -eq 0) { Write-Host "No connected Photons to update."; return }
  Write-Host ("[*] Updating Device OS on {0} connected Photon(s)..." -f $photons.Count)
  foreach ($d in $photons) { Invoke-UpdateOne $d | Out-Null }
}

# ===========================================================================
#  Main
# ===========================================================================

$inv = Get-Inventory
if ($inv.Count -eq 0) { Write-Host "No devices found on USB. Is a Photon plugged in?"; exit 3 }

# --- print the full inventory (ALL devices), numbering only claimable Photons
$numMap = @{}
$n = 0
Write-Host ""
Write-Host ('  {0,-3} {1,-10} {2,-7} {3,-26} {4}' -f '#','Mode','Port','Device ID','Account / Name')
Write-Host ('  {0,-3} {1,-10} {2,-7} {3,-26} {4}' -f '---',('-'*10),('-'*7),('-'*26),('-'*30))
foreach ($r in $inv) {
  $label = '-'
  if ($r.Claimable) { $n++; $numMap[[string]$n] = $r; $label = [string]$n }
  $port = if ($r.Port) { $r.Port } else { '-' }
  $acct =
    if     ($r.Owned)        { 'yours: ' + ($(if ($r.Name) { $r.Name } else { '(unnamed)' })) }
    elseif (-not $r.IsPhoton){ '(non-Photon - skip)' }
    else                     { 'CLAIMABLE (not in your account)' }
  Write-Host ('  {0,-3} {1,-10} {2,-7} {3,-26} {4}' -f $label, $r.Mode, $port, $r.Id, $acct)
}
Write-Host ""
Write-Host "  Only CLAIMABLE Photons (numbered) can be claimed; owned/non-Photon devices are locked out."

# --- non-interactive shortcut ---------------------------------------------
if ($Action -ne 'menu') {
  switch ($Action) {
    'auto'      { Run-Auto $inv }
    'claimall'  { Run-ClaimAll $inv }
    'updateall' { Run-UpdateAll $inv }
  }
  exit 0
}

# --- DEVICE_ID preselect (claim that one specific device, no menu) ---------
if ($DeviceId) {
  $row = $inv | Where-Object { $_.Id -eq $DeviceId.ToLower() } | Select-Object -First 1
  if (-not $row) { Write-Warning ("DEVICE_ID {0} is not connected on USB. Showing menu instead." -f $DeviceId) }
  elseif ($row.Owned) { Write-Warning ("DEVICE_ID {0} is already in your account ({1}) - nothing to claim." -f $DeviceId, $row.Name); exit 0 }
  else {
    if (-not (Assert-Wifi)) { exit 1 }
    $r = Invoke-ClaimOne $row
    if ($r) { Wait-Online @($r) }
    exit 0
  }
}

# --- menu -----------------------------------------------------------------
Write-Host ""
Write-Host "Actions:"
Write-Host "  [Enter]  AUTO  - update all DFU devices + claim all unclaimed listening devices  (default)"
Write-Host "  C        claim ALL claimable devices"
Write-Host "  U        update Device OS on ALL connected Photons"
Write-Host "  <#>      claim a single device by its number above"
Write-Host "  Q        quit"
Write-Host ""

$choice = (Read-Host "Choose [Enter=AUTO]").Trim()
switch -Regex ($choice) {
  '^$'        { Run-Auto $inv }
  '^[Aa]'     { Run-Auto $inv }
  '^[Cc]'     { Run-ClaimAll $inv }
  '^[Uu]'     { Run-UpdateAll $inv }
  '^[Qq]'     { Write-Host "Quit."; exit 0 }
  '^\d+$'     {
    if ($numMap.ContainsKey($choice)) {
      if (-not (Assert-Wifi)) { exit 1 }
      $r = Invoke-ClaimOne $numMap[$choice]
      if ($r) { Wait-Online @($r) }
    } else {
      Write-Warning "No claimable device numbered $choice. (Owned / non-Photon devices can't be claimed.)"
      exit 1
    }
  }
  default     { Write-Warning "Unrecognized choice '$choice'."; exit 1 }
}
exit 0
