@echo off
:: ============================================================
::  Launcher for Optimize-NetworkAdapter.ps1  —  v4.0
::  Auto-elevates to Administrator + bypasses ExecutionPolicy
::  https://github.com/Rezurmas/windows-network-optimizer
:: ============================================================

setlocal
cd /d "%~dp0"

:: Check for Administrator privileges (SID-based, works even if Server service is stopped)
whoami /groups | findstr S-1-16-12288 >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Administrator privileges required.
    echo [!] Restarting with elevated privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    if %errorLevel% neq 0 (
        echo [!] ERROR: Failed to launch elevated process.
        echo     Right-click Run-NIC-Optimizer.bat and choose 'Run as Administrator'
        pause
        exit /b 1
    )
    exit /b
)

echo ================================================================
echo   WINDOWS NETWORK OPTIMIZER  v4.0
echo   universal · Win 7 SP1+ / 8.1 / 10 / 11 / Server 2012+
echo ================================================================
echo.
echo   The script now has a built-in interactive mode selector.
echo   You can launch it directly for the full experience, or use
echo   the shortcuts below to jump straight to a specific mode:
echo.
echo   [1] INTERACTIVE  -  full menu: pick mode, adapter & DNS
echo   [2] THROUGHPUT   -  max bandwidth (downloads/streaming)
echo   [3] LOW LATENCY  -  min ping (gaming/CS2/Valorant)
echo   [4] BALANCED     -  daily mixed use
echo   [5] FULL MAX     -  throughput + telemetry OFF + Cloudflare DNS
echo.
echo   [R] Restore adapter settings from backup
echo   [Q] Quit
echo ================================================================
echo.

set "choice="
set /p choice=Choose option [1-5, R, Q]: 

if /i "%choice%"=="1"  goto interactive
if /i "%choice%"=="2"  goto throughput
if /i "%choice%"=="3"  goto lowlatency
if /i "%choice%"=="4"  goto balanced
if /i "%choice%"=="5"  goto fullmax
if /i "%choice%"=="R"  goto restore
if /i "%choice%"=="Q"  exit /b

:: Fallback: launch interactive for any other input
goto interactive

:interactive
echo.
echo Launching interactive mode — you will be able to pick mode, adapter & DNS inside the script...
timeout /t 2 /nobreak >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1"
goto end

:throughput
echo.
echo [MODE] Throughput — max bandwidth
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput
goto end

:lowlatency
echo.
echo [MODE] Low Latency — min ping (gaming)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode LowLatency
goto end

:balanced
echo.
echo [MODE] Balanced — daily mixed use
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Balanced
goto end

:fullmax
echo.
echo [MODE] FULL MAX — throughput + telemetry OFF + Cloudflare DNS + ALL adapters
echo.
echo ⚠  WARNING: This will disable Microsoft DiagTrack!
echo ⚠  WARNING: This applies to ALL Ethernet adapters!
echo ⚠  If you use AdBlock on your router (Pi-hole/AdGuard Home),
echo    DO NOT pick this. Use [2] Throughput instead.
echo.
set "confirm="
set /p confirm=Continue? [Y/N]: 
if /i not "%confirm%"=="Y" goto end
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput -DisableTelemetry -DnsProvider 1 -All
goto end

:restore
echo.
echo [MODE] Restore adapter settings from backup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Restore
goto end

:end
echo.
echo ─────────────────────────────────────────────────────────
echo   Done! Check the output above for results.
echo   Reboot recommended for full effect of registry tweaks.
echo ─────────────────────────────────────────────────────────
echo.
pause
