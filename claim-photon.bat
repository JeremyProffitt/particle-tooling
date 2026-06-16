@echo off
setlocal enabledelayedexpansion
REM ============================================================================
REM  claim-photon.bat
REM  Front door for the Particle Photon tooling. Loads .env, confirms login, and
REM  hands off to photon-manager.ps1, which inventories every USB device (serial
REM  AND DFU), shows a menu, and runs the chosen action:
REM
REM    * AUTO (default) - update Device OS on every device in DFU mode (blinking
REM      yellow) + claim every unclaimed device in listening mode (blinking blue)
REM    * Claim ALL claimable devices
REM    * Update Device OS on ALL connected Photons
REM    * Claim a single device chosen from the numbered list
REM
REM  Only Photons NOT already in your account are claimable (numbered); devices
REM  you already own and non-Photons are shown but locked out.
REM
REM  Mechanics the manager handles for you:
REM   * Device mode comes from `particle usb list` (the only command that sees a
REM     DFU device - it has no serial port).
REM   * The COM port changes in listening mode, so it is re-detected from
REM     `particle serial list` keyed off the stable device id.
REM   * Claim code is pushed BEFORE Wi-Fi (Wi-Fi restarts the device out of
REM     listening mode; it then reconnects presenting the code -> ownership moves).
REM
REM  .env keys (KEY=VALUE, # comments): WIFI_SSID, WIFI_PASSWORD, WIFI_SECURITY,
REM  and optional DEVICE_NAME, DEVICE_ID (claim just that one, skip the menu),
REM  SKIP_UPDATE=1. They are exported as environment variables for the manager.
REM ============================================================================

cd /d "%~dp0"
set "ENVFILE=%~dp0.env"
set "PSMGR=%~dp0photon-manager.ps1"
set "PSHELPER=%~dp0send-claim-code.ps1"

REM --- preflight -------------------------------------------------------------
where particle >nul 2>&1 || ( echo [ERROR] particle CLI not found in PATH.& goto :fail )
if not exist "%ENVFILE%"  ( echo [ERROR] No .env found. Copy .env.example to .env and edit it.& goto :fail )
if not exist "%PSMGR%"    ( echo [ERROR] photon-manager.ps1 missing next to this script.& goto :fail )
if not exist "%PSHELPER%" ( echo [ERROR] send-claim-code.ps1 missing next to this script.& goto :fail )

echo [*] Logged in as:
particle whoami || ( echo [ERROR] Not logged in. Run: particle login & goto :fail )

REM --- load .env into environment (the manager reads these via $env:) ---------
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENVFILE%") do set "%%A=%%B"
if not defined WIFI_SECURITY set "WIFI_SECURITY=WPA2_AES"

REM --- run the manager (interactive menu; AUTO is the default) ----------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSMGR%"
if errorlevel 1 goto :fail

echo.
echo [DONE]
endlocal
exit /b 0

:fail
echo.
echo [FAILED] See messages above.
endlocal
exit /b 1
