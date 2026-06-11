@echo off
:: ============================================================
::  Launcher for Optimize-NetworkAdapter.ps1
::  Auto-elevates to Administrator and bypasses ExecutionPolicy
::  https://github.com/Rezurmas/windows-network-optimizer
:: ============================================================

setlocal
cd /d "%~dp0"

:: NOTE: This file uses CRLF line endings. If edited on Linux/Mac,
:: convert with: sed -i 's/$/\r/' Run-NIC-Optimizer.bat (or use unix2dos)

:: Check for Administrator privileges
:: Using whoami is more robust than 'net session' (which fails if Server service is stopped)
whoami /groups | findstr S-1-16-12288 >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Administrator privileges required.
    echo [!] Restarting with elevated privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    if %errorLevel% neq 0 (
        echo [!] ERROR: Failed to launch elevated process (errorLevel=%errorLevel%). Right-click and Run as Administrator.
        pause
        exit /b 1
    )
    exit /b
)

echo ================================================================
echo   WINDOWS NETWORK OPTIMIZER  v3.0
echo   universal - Win 8.1 / 10 / 11 / Server 2012R2+
echo ================================================================
echo.
echo   OPTIMIZATION MODES:
echo.
echo   [1] THROUGHPUT   - max bandwidth     (downloads/streaming)
echo                       autotuning=experimental, cubic, LSO/RSC ON
echo.
echo   [2] LOW LATENCY  - min ping          (gaming/VoIP)
echo                       Nagle OFF, ctcp, LSO/RSC OFF, MMCSS=0
echo.
echo   [3] BALANCED     - compromise         (general use)
echo                       adaptive interrupts, cubic, Nagle OFF
echo.
echo   [4] FULL MAX     - throughput + telemetry OFF + Cloudflare DNS
echo                       WARNING: disables Microsoft DiagTrack!
echo.
echo ----------------------------------------------------------------
echo   [5] Restore adapter settings from backup
echo   [6] Adapter-only mode (skip registry/MMCSS/Nagle tweaks)
echo   [7] Exit
echo ================================================================
echo.
set "choice="
set /p choice=Choose option [1-7]: 

if "%choice%"=="1" goto throughput
if "%choice%"=="2" goto lowlatency
if "%choice%"=="3" goto balanced
if "%choice%"=="4" goto fullmax
if "%choice%"=="5" goto restore
if "%choice%"=="6" goto adapteronly
if "%choice%"=="7" exit /b
echo [!] Invalid choice "%choice%". Please enter 1-7.
goto end


:throughput
echo.
echo [MODE] Throughput - max bandwidth
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput
goto end

:lowlatency
echo.
echo [MODE] Low Latency - min ping (gaming)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode LowLatency
goto end

:balanced
echo.
echo [MODE] Balanced - compromise
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Balanced
goto end

:fullmax
echo.
echo [MODE] FULL MAX - throughput + telemetry OFF + Cloudflare DNS
echo.
echo WARNING: This option will disable Windows DiagTrack and set DNS to 1.1.1.1!
echo WARNING: This applies to ALL Ethernet adapters (-All mode)!
echo If you use AdBlock on your router (Pi-hole/AdGuard Home/OpenWrt), DO NOT pick this.
echo Use [1] Throughput instead to keep your router DNS.
echo.
set /p confirm=Continue? [Y/N]: 
if /i not "%confirm%"=="Y" goto end
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput -DisableTelemetry -DnsProvider 1 -All
goto end

:restore
echo.
echo [MODE] Restore - Loading backup adapter settings
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Restore
goto end

:adapteronly
echo.
echo [MODE] Adapter only (skip registry/MMCSS/Nagle tweaks)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput -NoRegistry
goto end

:end
echo.
pause
