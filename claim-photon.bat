@echo off
setlocal enabledelayedexpansion
REM ============================================================================
REM  claim-photon.bat
REM  End-to-end prep + force-claim for a Particle Gen2 Photon over USB.
REM
REM  Two gotchas this handles:
REM   * The COM port CHANGES when the device enters listening mode, so the port
REM     is (re)detected from `particle serial list` AFTER you put it in listening
REM     mode, keyed off the stable device ID.
REM   * Order matters: the claim code is pushed BEFORE Wi-Fi, because setting
REM     Wi-Fi restarts the device (it then reconnects presenting the claim code,
REM     so the cloud transfers ownership). Both happen in one listening session.
REM
REM  Steps:  (1) optional Device OS update   (DFU mode / blinking yellow)
REM          (-) put device in listening mode (blinking blue), detect its port
REM          (2) push a claim code           (listening mode)
REM          (3) set Wi-Fi from .env         (listening mode -> device restarts)
REM          (4) wait for cloud, verify, optional rename
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

REM --- pick the TARGET device id (stable across port changes) -----------------
REM Prefer DEVICE_ID from .env. Otherwise, if COM_PORT is unset, run discovery
REM so you can pick which device to claim from a menu.
if defined DEVICE_ID goto :have_target
if defined COM_PORT (
  for /f "tokens=5" %%i in ('particle serial list ^| findstr /I /C:"%COM_PORT% "') do set "DEVICE_ID=%%i"
) else (
  set "SELFILE=%TEMP%\photon_selection.env"
  del "%SELFILE%" >nul 2>&1
  echo [*] Discovering connected devices...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PSSELECT%" -OutFile "%SELFILE%"
  if errorlevel 1 ( echo [ERROR] Device discovery/selection failed. & goto :fail )
  if exist "%SELFILE%" for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%SELFILE%") do set "%%A=%%B"
  del "%SELFILE%" >nul 2>&1
)

:have_target
if defined DEVICE_ID ( echo [*] Target device: %DEVICE_ID% ) else ( echo [*] Target device: ^(auto-detect single device in listening mode^) )

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
REM  Listening mode, then (re)detect the live COM port for this device
REM ===========================================================================
echo.
REM Best-effort: flip the device into listening mode over USB so you don't have
REM to reach for the SETUP button. This is what rescues a device that's running
REM its app (breathing cyan) and answering serial with a "semaphore timeout" -
REM it won't take the claim code until it's actually in listening mode. The USB
REM control request times out if the device is mid-connect, so it's only a
REM convenience; the physical button below is the reliable fallback.
if defined DEVICE_ID (
  echo [*] Attempting to enter listening mode over USB ^(particle usb start-listening^)...
  particle usb start-listening %DEVICE_ID% >nul 2>&1 && echo [*] start-listening sent. || echo [warn] start-listening failed/timed out - use the SETUP button.
  timeout /t 3 /nobreak >nul
)
echo [*] Device should be in LISTENING mode ^(blinking blue^). If not, hold SETUP until blinking blue.
pause

echo [*] Locating the device on serial ^(its port can change in listening mode^)...
set "COM_PORT="
if not defined DEVICE_ID goto :resolve_single
for /f "tokens=1" %%p in ('particle serial list 2^>nul ^| findstr /I /C:"%DEVICE_ID%"') do set "COM_PORT=%%p"
goto :resolve_done
:resolve_single
set "cnt=0"
for /f "tokens=1,5" %%p in ('particle serial list 2^>nul ^| findstr /I /C:" - Photon - "') do ( set "COM_PORT=%%p" & set "DEVICE_ID=%%q" & set /a cnt+=1 )
if !cnt! GTR 1 ( echo [ERROR] Multiple devices on serial - set DEVICE_ID in .env to choose one. & goto :fail )
:resolve_done
if not defined COM_PORT ( echo [ERROR] Device not found on serial. Is it in listening mode ^(blinking blue^)? & goto :fail )
echo [*] Claiming %DEVICE_ID% on %COM_PORT%

REM ===========================================================================
REM  STEP 2 - generate + push claim code (listening mode, BEFORE Wi-Fi)
REM ===========================================================================
echo.
echo [2/4] Generating a claim code on your account and pushing it over serial...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSHELPER%" -Port %COM_PORT%
if errorlevel 1 ( echo [ERROR] Claim-code push failed. Re-check listening mode ^(blinking blue^) on %COM_PORT% and retry. & goto :fail )

REM ===========================================================================
REM  STEP 3 - set Wi-Fi (still listening; restarts device so it reconnects
REM           presenting the claim code -> ownership transfers)
REM ===========================================================================
echo.
set "WIFIJSON=%TEMP%\photon_wifi.json"
> "%WIFIJSON%" (
  echo {
  echo   "network": "%WIFI_SSID%",
  echo   "security": "%WIFI_SECURITY%",
  echo   "password": "%WIFI_PASSWORD%"
  echo }
)
echo [3/4] Sending Wi-Fi credentials ^(SSID: %WIFI_SSID%, %WIFI_SECURITY%^)...
particle serial wifi --port %COM_PORT% --file "%WIFIJSON%"
del "%WIFIJSON%" >nul 2>&1
if errorlevel 1 ( echo [ERROR] Wi-Fi setup failed - is it still in listening mode on %COM_PORT%? & goto :fail )

REM ===========================================================================
REM  STEP 4 - wait for cloud, verify, optional rename
REM ===========================================================================
echo.
echo [4/4] Waiting for it to connect and claim to your account ^(up to ~90s^)...
echo       LED should go: blinking green -^> blinking cyan -^> breathing cyan.
set /a tries=0
:waitloop
particle list | findstr /I /C:"%DEVICE_ID%" | findstr /I "online" >nul 2>&1 && goto :online
set /a tries+=1
if %tries% GEQ 30 ( echo [warn] Not online yet. breathing cyan=ok ^| breathing green=fix keys ^(particle keys doctor^) ^| blinking green=Wi-Fi creds. & goto :showstate )
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
