@echo off
setlocal enabledelayedexpansion
REM ============================================================================
REM  claim-photon.bat
REM  End-to-end prep + force-claim for a Particle Gen2 Photon over USB.
REM
REM  Steps:  (1) optional Device OS update   (DFU mode / blinking yellow)
REM          (2) set Wi-Fi from .env         (listening mode / blinking blue)
REM          (3) push a claim code           (listening mode / blinking blue)
REM          (4) reset, verify, optional rename
REM
REM  Wi-Fi settings come from a .env file next to this script (see .env.example).
REM  Reproduces what the removed `particle setup` used to do, so you can take
REM  ownership of a Photon you physically hold even if it's claimed elsewhere.
REM ============================================================================

cd /d "%~dp0"
set "ENVFILE=%~dp0.env"
set "PSHELPER=%~dp0send-claim-code.ps1"
set "PSSELECT=%~dp0select-device.ps1"

REM --- preflight -------------------------------------------------------------
where particle >nul 2>&1 || ( echo [ERROR] particle CLI not found in PATH.& goto :fail )
if not exist "%ENVFILE%" ( echo [ERROR] No .env found. Copy .env.example to .env and edit it.& goto :fail )
if not exist "%PSHELPER%" ( echo [ERROR] send-claim-code.ps1 missing next to this script.& goto :fail )
if not exist "%PSSELECT%" ( echo [ERROR] select-device.ps1 missing next to this script.& goto :fail )

echo [*] Logged in as:
particle whoami || ( echo [ERROR] Not logged in. Run: particle login & goto :fail )

REM --- load .env (KEY=VALUE, # comments) -------------------------------------
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENVFILE%") do set "%%A=%%B"

if not defined WIFI_SECURITY set "WIFI_SECURITY=WPA2_AES"
if not defined WIFI_SSID ( echo [ERROR] WIFI_SSID not set in .env & goto :fail )
if not defined WIFI_PASSWORD ( echo [ERROR] WIFI_PASSWORD not set in .env & goto :fail )

REM --- resolve device (discovery + selection) --------------------------------
REM If COM_PORT is set in .env we trust it; otherwise discover every connected
REM device, enrich with name/OS/online, and (when >1) show a menu to pick one.
if not defined COM_PORT (
  set "SELFILE=%TEMP%\photon_selection.env"
  del "!SELFILE!" >nul 2>&1
  echo [*] Discovering connected devices...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0select-device.ps1" -OutFile "!SELFILE!"
  if errorlevel 1 ( echo [ERROR] Device discovery/selection failed. & goto :fail )
  if exist "!SELFILE!" for /f "usebackq eol=# tokens=1,* delims==" %%A in ("!SELFILE!") do set "%%A=%%B"
  del "!SELFILE!" >nul 2>&1
)
if not defined COM_PORT ( echo [ERROR] No device selected. & goto :fail )
echo [*] Using port %COM_PORT%

REM --- resolve device id (from serial list line for this port) ---------------
if not defined DEVICE_ID (
  for /f "tokens=5" %%i in ('particle serial list ^| findstr /I /C:"%COM_PORT% "') do set "DEVICE_ID=%%i"
)
if not defined DEVICE_ID (
  echo [ERROR] Could not determine DEVICE_ID. Put the device in listening mode ^(blinking blue^) or set DEVICE_ID in .env.
  goto :fail
)
echo [*] Device ID: %DEVICE_ID%

REM ===========================================================================
REM  STEP 1 - optional Device OS update (requires DFU mode / blinking yellow)
REM ===========================================================================
echo.
if /I "%SKIP_UPDATE%"=="1" ( echo [1/4] Skipping Device OS update ^(SKIP_UPDATE=1^). ) else (
  choice /C YN /M "[1/4] Update Device OS now? Put device in DFU mode (blinking yellow) first"
  if errorlevel 2 (
    echo [1/4] Skipped.
  ) else (
    echo [1/4] Updating Device OS via USB...
    particle update
    if errorlevel 1 echo [warn] update returned an error - continuing.
  )
)

REM ===========================================================================
REM  STEP 2 - set Wi-Fi (requires listening mode / blinking blue)
REM ===========================================================================
echo.
echo [2/4] Put the device in LISTENING mode ^(hold SETUP until blinking blue^).
pause
set "WIFIJSON=%TEMP%\photon_wifi.json"
> "%WIFIJSON%" (
  echo {
  echo   "network": "%WIFI_SSID%",
  echo   "security": "%WIFI_SECURITY%",
  echo   "password": "%WIFI_PASSWORD%"
  echo }
)
echo [2/4] Sending Wi-Fi credentials ^(SSID: %WIFI_SSID%, %WIFI_SECURITY%^)...
particle serial wifi --port %COM_PORT% --file "%WIFIJSON%"
del "%WIFIJSON%" >nul 2>&1
if errorlevel 1 ( echo [ERROR] Wi-Fi setup failed - is it in listening mode on %COM_PORT%? & goto :fail )

REM ===========================================================================
REM  STEP 3 - generate + push claim code (still in listening mode)
REM ===========================================================================
echo.
echo [3/4] Generating a claim code on your account and pushing it over serial...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSHELPER%" -Port %COM_PORT%
if errorlevel 1 ( echo [ERROR] Claim-code push failed. Re-check listening mode and retry. & goto :fail )

REM ===========================================================================
REM  STEP 4 - reset, wait for cloud, verify, optional rename
REM ===========================================================================
echo.
echo [4/4] Resetting device so it reconnects and the cloud transfers ownership...
particle usb reset %DEVICE_ID% >nul 2>&1

echo [4/4] Waiting for it to come online in your account ^(up to ~90s^)...
set /a tries=0
:waitloop
particle list | findstr /I /C:"%DEVICE_ID%" | findstr /I "online" >nul 2>&1 && goto :online
set /a tries+=1
if %tries% GEQ 30 ( echo [warn] Not online yet. Check LED: breathing cyan=ok, breathing green=fix keys, blinking green=Wi-Fi. & goto :showstate )
timeout /t 3 /nobreak >nul
goto :waitloop

:online
echo [OK] Device is online and claimed to your account:
particle list | findstr /I /C:"%DEVICE_ID%"
if defined DEVICE_NAME (
  echo [*] Renaming to %DEVICE_NAME%...
  particle device rename %DEVICE_ID% %DEVICE_NAME%
)
echo.
echo [DONE] Claim complete.
goto :end

:showstate
particle list | findstr /I /C:"%DEVICE_ID%"
goto :end

:fail
echo.
echo [FAILED] See messages above.
endlocal
exit /b 1

:end
endlocal
exit /b 0
