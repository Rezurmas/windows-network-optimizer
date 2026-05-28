@echo off
:: Launcher dla Optimize-NetworkAdapter.ps1
:: Auto-elevuje do Administratora i omija ExecutionPolicy

setlocal
cd /d "%~dp0"

:: Sprawdz uprawnienia administratora
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Wymagane uprawnienia Administratora.
    echo [!] Uruchamiam ponownie z podwyzszonymi uprawnieniami...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ================================================================
echo   OPTYMALIZATOR KARTY SIECIOWEJ - WERSJA MAX (v2)
echo   Cudy WR3000 + RE550 / OpenWrt edition
echo ================================================================
echo.
echo  TRYBY OPTYMALIZACJI:
echo.
echo  [1] THROUGHPUT  - max przepustowosc  (download/streaming)
echo                    +experimental autotuning, +cubic, LSO/RSC ON
echo.
echo  [2] LOW LATENCY - min ping            (gaming/VoIP)
echo                    +Nagle off, ctcp, LSO/RSC OFF, MMCSS=0
echo.
echo  [3] BALANCED    - kompromis           (default)
echo                    +adaptive interrupts, +CUBIC, Nagle off
echo.
echo  [4] PELNY MAX   - throughput + telemetria off + DNS Cloudflare
echo                    UWAGA: wylaczy Microsoft DiagTrack!
echo.
echo ----------------------------------------------------------------
echo  [5] Przywroc ustawienia karty z backupu
echo  [6] Tylko karta sieciowa (bez registry/MMCSS/power)
echo  [7] Wyjdz
echo ================================================================
echo.
set /p choice=Wybierz opcje [1-7]: 

if "%choice%"=="1" goto throughput
if "%choice%"=="2" goto lowlatency
if "%choice%"=="3" goto balanced
if "%choice%"=="4" goto fullmax
if "%choice%"=="5" goto restore
if "%choice%"=="6" goto adapteronly
if "%choice%"=="7" exit /b
goto throughput

:throughput
echo.
echo [TRYB] Throughput - max przepustowosc
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput
goto end

:lowlatency
echo.
echo [TRYB] Low Latency - min ping (gaming)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode LowLatency
goto end

:balanced
echo.
echo [TRYB] Balanced - kompromis
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Balanced
goto end

:fullmax
echo.
echo [TRYB] PELNY MAX - throughput + telemetry off + Cloudflare DNS
echo.
echo UWAGA: Ta opcja wylaczy Windows DiagTrack i ustawi DNS na 1.1.1.1!
echo Jesli masz AdBlock na routerze NIE wybieraj tej opcji
echo (uzyj [1] Throughput zamiast tego).
echo.
set /p confirm=Kontynuowac? [T/N]: 
if /i not "%confirm%"=="T" goto end
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput -DisableTelemetry -DnsProvider 1 -All
goto end

:restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Restore
goto end

:adapteronly
echo.
echo [TRYB] Tylko karta sieciowa (bez registry/MMCSS)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-NetworkAdapter.ps1" -Mode Throughput -NoRegistry
goto end

:end
echo.
pause
